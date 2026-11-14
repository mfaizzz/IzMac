import Foundation

// Plain Foundation-only logic so it can be unit tested.

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseISO(_ s: String) -> Date? {
    if let d = isoFrac.date(from: s) ?? isoPlain.date(from: s) { return d }
    // Odd fractional precision (e.g. 6 digits): drop the fraction.
    return isoPlain.date(from: s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
}

/// 0...100 remaining. A window whose reset time has passed counts as fully reset.
func remainingPercent(used: Double, resetsAt: Date?, now: Date) -> Int {
    if let r = resetsAt, r < now { return 100 }
    return Int(max(0, min(100, 100 - used)).rounded())
}

// MARK: - Codex

struct CodexLimit: Equatable {
    var usedPercent: Double
    var resetsAt: Date?
}

struct CodexFile: Equatable {
    var rateAt: Date?
    var primary: CodexLimit?
    var secondary: CodexLimit?
    var totalTokens = 0
    var day: Date?
}

struct CodexSummary: Equatable {
    var primary: CodexLimit?
    var secondary: CodexLimit?
    var allTime = 0
    var peakDay = 0
    var yesterday = 0
}

private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

private func codexLimit(_ v: Any?, at ts: Date) -> CodexLimit? {
    guard let d = v as? [String: Any], let used = num(d["used_percent"]) else { return nil }
    var reset: Date?
    if let r = num(d["resets_at"]) {
        reset = Date(timeIntervalSince1970: r)
    } else if let s = num(d["resets_in_seconds"]) {
        reset = ts.addingTimeInterval(s)
    }
    return CodexLimit(usedPercent: used, resetsAt: reset)
}

func parseCodexFile(_ text: String, calendar: Calendar = .current) -> CodexFile {
    var f = CodexFile()
    for line in text.split(separator: "\n") where line.contains("token_count") {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let p = obj["payload"] as? [String: Any],
              p["type"] as? String == "token_count",
              let ts = (obj["timestamp"] as? String).flatMap(parseISO) else { continue }
        if let info = p["info"] as? [String: Any],
           let usage = info["total_token_usage"] as? [String: Any],
           let total = num(usage["total_tokens"]) {
            f.totalTokens = Int(total)
            f.day = calendar.startOfDay(for: ts)
        }
        if let rl = p["rate_limits"] as? [String: Any], f.rateAt.map({ ts >= $0 }) ?? true {
            f.rateAt = ts
            f.primary = codexLimit(rl["primary"], at: ts)
            f.secondary = codexLimit(rl["secondary"], at: ts)
        }
    }
    return f
}

func summarizeCodex(_ files: [CodexFile], now: Date, calendar: Calendar = .current) -> CodexSummary {
    var s = CodexSummary()
    var perDay: [Date: Int] = [:]
    var newest: CodexFile?
    for f in files {
        s.allTime += f.totalTokens
        if let d = f.day { perDay[d, default: 0] += f.totalTokens }
        if let t = f.rateAt, newest?.rateAt.map({ t > $0 }) ?? true { newest = f }
    }
    s.primary = newest?.primary
    s.secondary = newest?.secondary
    s.peakDay = perDay.values.max() ?? 0
    if let y = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) {
        s.yesterday = perDay[y] ?? 0
    }
    return s
}

struct CachedFile {
    var mtime: Date
    var file: CodexFile
}

/// Returns nil summary when the sessions folder does not exist.
func scanCodex(root: URL, cache: [String: CachedFile], now: Date) -> (CodexSummary?, [String: CachedFile]) {
    guard FileManager.default.fileExists(atPath: root.path),
          let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return (nil, cache) }
    var next: [String: CachedFile] = [:]
    for case let url as URL in en where url.pathExtension == "jsonl" {
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let c = cache[url.path], c.mtime == m {
            next[url.path] = c
            continue
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        next[url.path] = CachedFile(mtime: m, file: parseCodexFile(text))
    }
    return (summarizeCodex(next.values.map { $0.file }, now: now), next)
}

// MARK: - Waktu solat (api.waktusolat.app v2)

struct SolatDay: Codable, Equatable {
    var date: String
    var hijri: String?
    var imsak: Double?
    var fajr: Double?
    var syuruk: Double?
    var dhuhr: Double?
    var asr: Double?
    var maghrib: Double?
    var isha: Double?
}

struct SolatResponse: Codable, Equatable {
    var zone: String?
    var prayerTime: [SolatDay]
}

struct SolatTime: Equatable {
    var name: String
    var date: Date
}

let prayerNames = ["Subuh", "Zohor", "Asar", "Maghrib", "Isyak"]

extension SolatDay {
    /// Imsak, Subuh, Syuruk, Zohor, Asar, Maghrib, Isyak (missing ones skipped; Imsak is Subuh - 10 min if absent).
    var times: [SolatTime] {
        let pairs: [(String, Double?)] = [
            ("Imsak", imsak ?? fajr.map { $0 - 600 }), ("Subuh", fajr), ("Syuruk", syuruk),
            ("Zohor", dhuhr), ("Asar", asr), ("Maghrib", maghrib), ("Isyak", isha),
        ]
        return pairs.compactMap { n, t in t.map { SolatTime(name: n, date: Date(timeIntervalSince1970: $0)) } }
    }
}

func dayString(_ d: Date, calendar: Calendar = .current) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = calendar.timeZone
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
}

func solatToday(_ days: [SolatDay], now: Date, calendar: Calendar = .current) -> SolatDay? {
    let key = dayString(now, calendar: calendar)
    return days.first { $0.date == key }
}

/// Next of Subuh/Zohor/Asar/Maghrib/Isyak strictly after `now`, looking across all days given.
func nextPrayer(_ days: [SolatDay], now: Date) -> SolatTime? {
    days.flatMap { $0.times }
        .filter { prayerNames.contains($0.name) && $0.date > now }
        .min { $0.date < $1.date }
}

private let hijriMonths = ["Muharram", "Safar", "Rabiulawal", "Rabiulakhir", "Jamadilawal", "Jamadilakhir",
                           "Rejab", "Syaaban", "Ramadan", "Syawal", "Zulkaedah", "Zulhijjah"]

/// "1446-09-22" -> "22 Ramadan 1446"; anything unexpected is returned unchanged.
func hijriText(_ s: String) -> String {
    let p = s.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3, (1...12).contains(p[1]) else { return s }
    return "\(p[2]) \(hijriMonths[p[1] - 1]) \(p[0])"
}

func countdownText(from now: Date, to target: Date) -> String {
    let m = max(0, Int(target.timeIntervalSince(now) / 60))
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

// MARK: - Claude usage

struct ClaudePeriod: Codable, Equatable {
    var utilization: Double?
    var resets_at: String?
}

struct ClaudeUsage: Codable, Equatable {
    var five_hour: ClaudePeriod?
    var seven_day: ClaudePeriod?
}

func parseClaudeToken(_ data: Data) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let t = oauth["accessToken"] as? String, !t.isEmpty else { return nil }
    return t
}

// MARK: - Codex app-server (account/rateLimits/read, account/usage/read)

struct CodexWindow: Equatable {
    var minutes: Int?
    var remaining: Int
    var resets: Date?
}

struct CodexSnapshot: Equatable {
    var windows: [CodexWindow] = []
    var lifetimeTokens: Int?
    var peakDailyTokens: Int?
    var latestLabel: String?
    var latestTokens: Int?
    var note: String?
    var updated: Date?
}

/// stage: 0 initialize sent, 1 limits requested, 2 usage requested, 3 finished.
struct CodexRPC {
    var stage = 0
    var snapshot = CodexSnapshot()
    var failure: String?
}

let codexHello = #"{"id":0,"method":"initialize","params":{"clientInfo":{"name":"izmac","version":"0.2.0"}}}"#

func windowLabel(_ minutes: Int?) -> String {
    guard let m = minutes, m > 0 else { return "Limit" }
    if m == 300 { return "5h" }
    if m == 10080 { return "Week" }
    if m % 1440 == 0 { return "\(m / 1440)d" }
    return m >= 60 ? "\(Int((Double(m) / 60).rounded()))h" : "\(m)m"
}

private func codexWindow(_ v: Any?) -> CodexWindow? {
    guard let d = v as? [String: Any], let used = num(d["usedPercent"]) else { return nil }
    return CodexWindow(
        minutes: num(d["windowDurationMins"]).map { Int($0) },
        remaining: Int(max(0, min(100, 100 - used)).rounded()),
        resets: num(d["resetsAt"]).map { Date(timeIntervalSince1970: $0) })
}

/// Pure message handler: applies one decoded server message to `state` and returns the lines to send next.
func codexStep(_ msg: [String: Any], state: inout CodexRPC) -> [String] {
    guard msg["method"] == nil, let id = (msg["id"] as? NSNumber)?.intValue else { return [] }
    let failed = msg["error"] != nil && !(msg["error"] is NSNull)
    let result = msg["result"] as? [String: Any]
    switch (id, state.stage) {
    case (0, 0):
        if failed {
            state.failure = "Codex app-server failed to start"
            state.stage = 3
            return []
        }
        state.stage = 1
        return [#"{"method":"initialized"}"#, #"{"id":1,"method":"account/rateLimits/read"}"#]
    case (1, 1):
        let byId = result?["rateLimitsByLimitId"] as? [String: Any]
        let bucket = (byId?["codex"] as? [String: Any]) ?? (result?["rateLimits"] as? [String: Any])
        let windows = [codexWindow(bucket?["primary"]), codexWindow(bucket?["secondary"])].compactMap { $0 }
        if failed || result == nil {
            state.failure = "Usage unavailable. Check your Codex sign-in."
        } else if windows.isEmpty {
            state.failure = "No usage windows available"
        }
        if state.failure != nil {
            state.stage = 3
            return []
        }
        state.snapshot.windows = windows
        state.stage = 2
        return [#"{"id":2,"method":"account/usage/read"}"#]
    case (2, 2):
        state.stage = 3
        if failed {
            state.snapshot.note = "Token counts unavailable"
            return []
        }
        let summary = result?["summary"] as? [String: Any]
        state.snapshot.lifetimeTokens = num(summary?["lifetimeTokens"]).map { Int($0) }
        state.snapshot.peakDailyTokens = num(summary?["peakDailyTokens"]).map { Int($0) }
        let buckets = result?["dailyUsageBuckets"] as? [[String: Any]] ?? []
        let days = buckets.compactMap { b -> (String, Int)? in
            guard let d = b["startDate"] as? String, let t = num(b["tokens"]) else { return nil }
            return (d, Int(t))
        }
        if let last = days.max(by: { $0.0 < $1.0 }) {
            // A daily bucket is a date label, shown as dd/MM/yyyy without timezone shifting.
            let p = last.0.prefix(10).split(separator: "-")
            state.snapshot.latestLabel = p.count == 3 ? "\(p[2])/\(p[1])/\(p[0])" : last.0
            state.snapshot.latestTokens = last.1
        }
        return []
    default:
        return []
    }
}

/// Maps the local-JSONL fallback onto the same card.
func codexSnapshot(_ s: CodexSummary, now: Date) -> CodexSnapshot {
    func w(_ l: CodexLimit?, _ minutes: Int) -> CodexWindow? {
        l.map { CodexWindow(minutes: minutes, remaining: remainingPercent(used: $0.usedPercent, resetsAt: $0.resetsAt, now: now), resets: $0.resetsAt) }
    }
    return CodexSnapshot(
        windows: [w(s.primary, 300), w(s.secondary, 10080)].compactMap { $0 },
        lifetimeTokens: s.allTime, peakDailyTokens: s.peakDay,
        latestLabel: "Yesterday", latestTokens: s.yesterday, note: nil, updated: now)
}
