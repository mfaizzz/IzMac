import Foundation
import ServiceManagement
import SwiftUI

struct UsageLine {
    var remaining: Int
    var resets: Date?
}

struct ClaudeSnapshot {
    var five: UsageLine?
    var week: UsageLine?
}

private struct SolatCache: Codable {
    var fetchedOn: String
    var response: SolatResponse
}

@MainActor
final class Model: ObservableObject {
    @Published var now = Date()
    @Published var quote = quotes.randomElement() ?? ""
    @Published var solat: SolatResponse?
    @Published var codex: CodexSnapshot?
    @Published var codexMessage: String?
    @Published var claude: ClaudeSnapshot?
    @Published var claudeMessage: String? = "Loading..."
    @Published var battery: BatteryInfo?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var codexBusy = false
    private var codexCache: [String: CachedFile] = [:]
    private var coordinate: (Double, Double)?
    private var solatFetchedOn: String?
    private var claudeLast = Date.distantPast
    private var claudeBackoff = Date.distantPast
    private let locator = Locator()

    private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IzMac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("solat.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Model.cacheURL),
           let c = try? JSONDecoder().decode(SolatCache.self, from: data) {
            solat = c.response
            solatFetchedOn = c.fetchedOn
        }
        locator.onCoordinate = { [weak self] lat, lon in
            Task { @MainActor in
                self?.coordinate = (lat, lon)
                await self?.refreshSolat(force: true)
            }
        }
        locator.start()
        Task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    // MARK: derived

    var today: SolatDay? { solat.flatMap { solatToday($0.prayerTime, now: now) } }
    var next: SolatTime? { solat.flatMap { nextPrayer($0.prayerTime, now: now) } }

    var menuTitle: String {
        var parts: [String] = []
        if let p = codex?.windows.first(where: { $0.minutes == 300 }) {
            parts.append("Cx \(p.remaining)%")
        }
        if let f = claude?.five { parts.append("Cl \(f.remaining)%") }
        if let n = next { parts.append("\(n.name) \(timeText(n.date))") }
        return parts.isEmpty ? "IzMac" : parts.joined(separator: " · ")
    }

    // MARK: actions

    func opened() {
        quote = quotes.randomElement() ?? quote
        refresh()
    }

    func refresh(force: Bool = false) {
        now = Date()
        battery = readBattery()
        Task { await refreshCodex() }
        Task { await refreshSolat(force: force) }
        Task { await refreshClaude(force: force) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func refreshCodex() async {
        if codexBusy { return }
        codexBusy = true
        defer { codexBusy = false }
        if let bin = codexBinaryPath() {
            let r = await Task.detached(priority: .utility) { runCodexAppServer(path: bin) }.value
            var s = r.0
            s?.updated = Date()
            codex = s
            codexMessage = r.1
            return
        }
        codexMessage = nil
        let cache = codexCache
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let t = Date()
        let result = await Task.detached(priority: .utility) { scanCodex(root: root, cache: cache, now: t) }.value
        codexCache = result.1
        codex = result.0.map { codexSnapshot($0, now: t) }
    }

    private func refreshSolat(force: Bool) async {
        let today = dayString(Date())
        if !force && solatFetchedOn == today && solat != nil { return }
        let path = coordinate.map { "gps/\($0.0)/\($0.1)" } ?? "WLY01"
        guard let url = URL(string: "https://api.waktusolat.app/v2/solat/\(path)") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let r = try JSONDecoder().decode(SolatResponse.self, from: data)
            solat = r
            solatFetchedOn = today
            if let out = try? JSONEncoder().encode(SolatCache(fetchedOn: today, response: r)) {
                try? out.write(to: Model.cacheURL)
            }
        } catch {}
    }

    private func refreshClaude(force: Bool) async {
        let t = Date()
        if t < claudeBackoff { return }
        if !force && t.timeIntervalSince(claudeLast) < 300 { return }
        claudeLast = t
        guard let token = await Task.detached(operation: { readClaudeToken() }).value else {
            claude = nil
            claudeMessage = "Run /login in Claude Code"
            return
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200:
                let u = try JSONDecoder().decode(ClaudeUsage.self, from: data)
                claude = ClaudeSnapshot(five: usageLine(u.five_hour), week: usageLine(u.seven_day))
                claudeMessage = nil
            case 401:
                claude = nil
                claudeMessage = "Run /login in Claude Code"
            case 429:
                let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) } ?? 900
                claudeBackoff = Date().addingTimeInterval(max(wait, 300))
                if claude == nil { claudeMessage = "Rate limited, retrying later" }
            default:
                if claude == nil { claudeMessage = "Claude usage unavailable" }
            }
        } catch {
            if claude == nil { claudeMessage = "Claude usage unavailable" }
        }
    }

    private func usageLine(_ p: ClaudePeriod?) -> UsageLine? {
        guard let used = p?.utilization else { return nil }
        let reset = p?.resets_at.flatMap(parseISO)
        return UsageLine(remaining: remainingPercent(used: used, resetsAt: reset, now: Date()), resets: reset)
    }
}

func timeText(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "h:mm a"
    return f.string(from: d)
}

func resetText(_ d: Date) -> String {
    "Resets " + d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
}

func tokenText(_ n: Int) -> String { n.formatted() }
