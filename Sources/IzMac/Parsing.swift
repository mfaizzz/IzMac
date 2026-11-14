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
