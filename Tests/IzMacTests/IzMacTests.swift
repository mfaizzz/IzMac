import XCTest
@testable import IzMac

final class IzMacTests: XCTestCase {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func codexLine(_ ts: String, total: Int, used: Double, reset: String) -> String {
        """
        {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(total)}},"rate_limits":{"primary":{"used_percent":\(used),"window_minutes":300,\(reset)},"secondary":{"used_percent":40.5,"window_minutes":10080,"resets_in_seconds":3000}}}}
        """
    }

    func testCodexParsing() {
        let text = [
            codexLine("2026-11-13T10:00:00.000Z", total: 1000, used: 10, reset: "\"resets_at\":1790000000"),
            #"{"timestamp":"2026-11-13T10:30:00.000Z","type":"session_meta","payload":{}}"#,
            codexLine("2026-11-13T11:00:00.000Z", total: 2500, used: 20, reset: "\"resets_at\":1790003600"),
            #"{"timestamp":"2026-11-13T11:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}"#,
        ].joined(separator: "\n")
        let f = parseCodexFile(text, calendar: utc)
        XCTAssertEqual(f.totalTokens, 2500)
        XCTAssertEqual(f.primary?.usedPercent, 20)
        XCTAssertEqual(f.primary?.resetsAt, Date(timeIntervalSince1970: 1790003600))
        XCTAssertEqual(f.secondary?.resetsAt, parseISO("2026-11-13T11:50:00Z"))
    }

    func testCodexSummary() {
        let a = parseCodexFile(codexLine("2026-11-13T11:00:00.000Z", total: 2500, used: 20, reset: "\"resets_at\":1790003600"), calendar: utc)
        let b = parseCodexFile(codexLine("2026-11-14T09:00:00.000Z", total: 700, used: 30, reset: "\"resets_at\":1790009999"), calendar: utc)
        let s = summarizeCodex([a, b], now: parseISO("2026-11-14T12:00:00Z")!, calendar: utc)
        XCTAssertEqual(s.allTime, 3200)
        XCTAssertEqual(s.peakDay, 2500)
        XCTAssertEqual(s.yesterday, 2500)
        XCTAssertEqual(s.primary?.usedPercent, 30)
        XCTAssertEqual(remainingPercent(used: 30, resetsAt: Date(timeIntervalSince1970: 1790009999), now: Date(timeIntervalSince1970: 1790010000)), 100)
        XCTAssertEqual(remainingPercent(used: 30, resetsAt: nil, now: Date()), 70)
    }

    let solatJSON = """
    {"zone":"WLY01","origin":null,"prayerTime":[
      {"date":"2026-11-14","hijri":"1448-06-03","day":6,"imsak":null,"fajr":1794632400,"syuruk":1794636000,"isyraq":1794636900,"dhuhr":1794657600,"asr":1794668400,"maghrib":1794679200,"isha":1794682800},
      {"date":"2026-11-15","hijri":"1448-06-04","day":7,"fajr":1794718860,"syuruk":1794722460,"dhuhr":1794744060,"asr":1794754860,"maghrib":1794765660,"isha":1794769260}
    ]}
    """

    func testSolatDecodingAndNextPrayer() throws {
        let r = try JSONDecoder().decode(SolatResponse.self, from: Data(solatJSON.utf8))
        XCTAssertEqual(r.zone, "WLY01")
        XCTAssertEqual(r.prayerTime.count, 2)
        let now = parseISO("2026-11-14T13:00:00Z")!
        let today = solatToday(r.prayerTime, now: now, calendar: utc)
        XCTAssertEqual(today?.hijri, "1448-06-03")
        XCTAssertEqual(today?.times.count, 7)
        XCTAssertEqual(today?.times.first?.name, "Imsak")
        XCTAssertEqual(nextPrayer(r.prayerTime, now: now)?.name, "Asar")
        let late = parseISO("2026-11-14T20:00:00Z")!
        XCTAssertEqual(nextPrayer(r.prayerTime, now: late)?.date, Date(timeIntervalSince1970: 1794718860))
        XCTAssertEqual(hijriText("1448-06-03"), "3 Jamadilakhir 1448")
    }

    func testClaudeUsage() throws {
        let json = #"{"five_hour":{"utilization":8.0,"resets_at":"2026-11-14T09:00:00.123456+00:00"},"seven_day":{"utilization":77.0,"resets_at":"2026-11-20T19:00:00Z"},"extra_usage":{"is_enabled":false}}"#
        let u = try JSONDecoder().decode(ClaudeUsage.self, from: Data(json.utf8))
        XCTAssertEqual(u.five_hour?.utilization, 8)
        XCTAssertNotNil(parseISO(u.five_hour!.resets_at!))
        XCTAssertNotNil(parseISO(u.seven_day!.resets_at!))
        let cred = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"x"}}"#
        XCTAssertEqual(parseClaudeToken(Data(cred.utf8)), "tok")
        XCTAssertNil(parseClaudeToken(Data("{}".utf8)))
    }

    func jsonMsg(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    func testCodexAppServerExchange() {
        var st = CodexRPC()
        XCTAssertEqual(codexStep(jsonMsg(#"{"method":"note","params":{}}"#), state: &st), [])
        XCTAssertEqual(st.stage, 0)
        let l0 = codexStep(jsonMsg(#"{"id":0,"result":{"userAgent":"x"}}"#), state: &st)
        XCTAssertEqual(l0, [#"{"method":"initialized"}"#, #"{"id":1,"method":"account/rateLimits/read"}"#])
        let l1 = codexStep(jsonMsg(#"""
        {"id":1,"result":{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{
          "primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1790000000},
          "secondary":{"usedPercent":null,"windowDurationMins":10080,"resetsAt":1790600000}}}}}
        """#), state: &st)
        XCTAssertEqual(l1, [#"{"id":2,"method":"account/usage/read"}"#])
        XCTAssertEqual(st.snapshot.windows, [CodexWindow(minutes: 300, remaining: 75, resets: Date(timeIntervalSince1970: 1790000000))])
        let l2 = codexStep(jsonMsg(#"""
        {"id":2,"result":{"summary":{"lifetimeTokens":1234567,"peakDailyTokens":89000},"dailyUsageBuckets":[
          {"startDate":"2026-11-14","tokens":5000},{"startDate":"2026-11-13","tokens":100},{"startDate":"2026-11-15","tokens":null}]}}
        """#), state: &st)
        XCTAssertEqual(l2, [])
        XCTAssertEqual(st.stage, 3)
        XCTAssertNil(st.failure)
        XCTAssertEqual(st.snapshot.lifetimeTokens, 1234567)
        XCTAssertEqual(st.snapshot.peakDailyTokens, 89000)
        XCTAssertEqual(st.snapshot.latestLabel, "14/11/2026")
        XCTAssertEqual(st.snapshot.latestTokens, 5000)
        XCTAssertNil(st.snapshot.note)

        // Fallback bucket, clamping, and error replies.
        var s2 = CodexRPC(stage: 1)
        _ = codexStep(jsonMsg(#"{"id":1,"result":{"rateLimits":{"primary":{"usedPercent":130,"windowDurationMins":300},"secondary":{"usedPercent":40,"windowDurationMins":10080}}}}"#), state: &s2)
        XCTAssertEqual(s2.snapshot.windows.map { $0.remaining }, [0, 60])
        _ = codexStep(jsonMsg(#"{"id":2,"error":{"message":"no"}}"#), state: &s2)
        XCTAssertEqual(s2.snapshot.note, "Token counts unavailable")
        XCTAssertEqual(s2.snapshot.windows.count, 2)
        var s3 = CodexRPC(stage: 1)
        _ = codexStep(jsonMsg(#"{"id":1,"error":{"message":"auth"}}"#), state: &s3)
        XCTAssertEqual(s3.failure, "Usage unavailable. Check your Codex sign-in.")
        XCTAssertEqual(windowLabel(300), "5h")
        XCTAssertEqual(windowLabel(10080), "Week")
        XCTAssertEqual(windowLabel(120), "2h")
        XCTAssertEqual(windowLabel(2880), "2d")
    }
}
