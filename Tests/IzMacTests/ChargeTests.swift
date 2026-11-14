import XCTest
@testable import IzMac

final class ChargeTests: XCTestCase {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func at(_ h: Int, _ m: Int = 0, _ s: Int = 0, day: Int = 14) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m, second: s))!
    }

    func cfg(_ f: (inout ChargeConfig) -> Void = { _ in }) -> ChargeConfig {
        var c = ChargeConfig()
        c.enabled = true
        f(&c)
        return c
    }

    @discardableResult
    func step(_ s: inout ChargeState, _ pct: Int, _ c: ChargeConfig, plugged: Bool = true, temp: Double? = 25,
              now: Date = Date(timeIntervalSince1970: 1_800_000_000), canDischarge: Bool = true) -> ChargeOutput {
        let (o, n) = chargeStep(ChargeInput(percent: pct, plugged: plugged, tempC: temp, now: now,
                                            canDischarge: canDischarge, cfg: c), s, calendar: utc)
        s = n
        return o
    }

    func testLimitReached() {
        var s = ChargeState()
        let c = cfg()
        XCTAssertTrue(step(&s, 79, c).charging)
        let o = step(&s, 80, c)
        XCTAssertFalse(o.charging)
        XCTAssertTrue(o.adapter)
        XCTAssertEqual(o.status, "Holding at 80%")
        XCTAssertTrue(step(&s, 79, c).charging)   // without sailing it resumes right below the limit
        XCTAssertEqual(step(&s, 60, c).status, "Charging to 80%")
    }

    func testControlOffIsSafe() {
        var s = ChargeState()
        let o = step(&s, 95, ChargeConfig.safe)
        XCTAssertTrue(o.charging && o.adapter)
        XCTAssertEqual(o.led, .system)
    }

    func testSailingHysteresis() {
        var s = ChargeState()
        let c = cfg { $0.sailing = true; $0.sailingRange = 5 }
        XCTAssertFalse(step(&s, 80, c).charging)
        XCTAssertFalse(step(&s, 78, c).charging)
        XCTAssertFalse(step(&s, 76, c).charging)
        XCTAssertTrue(step(&s, 75, c).charging)
        XCTAssertTrue(step(&s, 77, c).charging)   // keeps charging up to the limit
        XCTAssertFalse(step(&s, 80, c).charging)
    }

    func testTopUpClearsAtFullAndOnUnplug() {
        var s = ChargeState()
        var c = cfg()
        step(&s, 90, c)                       // baseline command id
        XCTAssertFalse(step(&s, 90, c).charging)
        c.commandId = 1; c.command = .topUp
        var o = step(&s, 90, c)
        XCTAssertTrue(o.charging)
        XCTAssertEqual(o.status, "Topping up to 100%")
        XCTAssertEqual(step(&s, 99, c).mode, "topUp")
        o = step(&s, 100, c)
        XCTAssertEqual(o.mode, "normal")
        XCTAssertFalse(o.charging)
        c.commandId = 2
        XCTAssertEqual(step(&s, 85, c).mode, "topUp")
        XCTAssertEqual(step(&s, 85, c, plugged: false).mode, "normal")
    }

    func testHeatPauseAndResume() {
        var s = ChargeState()
        let c = cfg { $0.heatProtection = true; $0.heatThreshold = 35 }
        XCTAssertTrue(step(&s, 50, c, temp: 34).charging)
        var o = step(&s, 50, c, temp: 35)
        XCTAssertFalse(o.charging)
        XCTAssertEqual(o.status, "Heat protection: paused")
        XCTAssertFalse(step(&s, 50, c, temp: 34).charging)
        o = step(&s, 50, c, temp: 33)
        XCTAssertTrue(o.charging)
    }

    func testAutomaticDischarge() {
        var s = ChargeState()
        let c = cfg { $0.autoDischarge = true }
        var o = step(&s, 85, c)
        XCTAssertFalse(o.adapter)
        XCTAssertFalse(o.charging)
        XCTAssertEqual(o.status, "Discharging to 80%")
        o = step(&s, 80, c)
        XCTAssertTrue(o.adapter)
        XCTAssertEqual(step(&s, 85, c, plugged: false).adapter, true)
        XCTAssertTrue(step(&s, 85, c, canDischarge: false).adapter)
    }

    func testManualDischargeStopsAtLimit() {
        var s = ChargeState()
        var c = cfg()
        step(&s, 90, c)
        c.commandId = 1; c.command = .discharge
        XCTAssertFalse(step(&s, 90, c).adapter)
        XCTAssertFalse(step(&s, 81, c).adapter)
        XCTAssertTrue(step(&s, 80, c).adapter)
        XCTAssertTrue(step(&s, 85, c).adapter)
    }

    func testNeverDischargeAtOrBelowTen() {
        var s = ChargeState()
        var c = cfg()
        step(&s, 50, c)
        c.commandId = 1; c.command = .calibrate
        step(&s, 100, c)                        // charge step done, now discharging
        XCTAssertFalse(step(&s, 11, c).adapter)
        let o = step(&s, 10, c)
        XCTAssertTrue(o.adapter)
        XCTAssertEqual(o.status, "Calibrating: step 3 of 5")
        // even a stale discharge request cannot disable the adapter at 10 % or below
        var s2 = ChargeState()
        s2.calStep = 2
        XCTAssertTrue(step(&s2, 9, cfg()).adapter)
    }

    func testFullCalibrationSequence() {
        var s = ChargeState()
        var c = cfg { $0.limit = 80 }
        let t0 = at(10)
        step(&s, 50, c, now: t0)
        c.commandId = 1; c.command = .calibrate
        var o = step(&s, 50, c, now: t0.addingTimeInterval(2))
        XCTAssertEqual(o.status, "Calibrating: step 1 of 5")
        XCTAssertTrue(o.charging)
        o = step(&s, 100, c, now: t0.addingTimeInterval(4))     // -> step 2
        XCTAssertEqual(o.status, "Calibrating: step 2 of 5")
        XCTAssertFalse(o.adapter)
        step(&s, 40, c, now: t0.addingTimeInterval(6))
        o = step(&s, 10, c, now: t0.addingTimeInterval(8))      // -> step 3
        XCTAssertEqual(o.status, "Calibrating: step 3 of 5")
        XCTAssertTrue(o.charging)
        o = step(&s, 100, c, now: t0.addingTimeInterval(10))    // -> step 4, hold starts
        XCTAssertEqual(o.status, "Calibrating: step 4 of 5")
        XCTAssertTrue(o.charging)
        o = step(&s, 100, c, now: t0.addingTimeInterval(10 + 3599))
        XCTAssertEqual(o.status, "Calibrating: step 4 of 5")
        o = step(&s, 100, c, now: t0.addingTimeInterval(10 + 3600))
        XCTAssertEqual(o.status, "Calibrating: step 5 of 5")
        XCTAssertFalse(o.adapter)
        let end = t0.addingTimeInterval(10 + 3700)
        o = step(&s, 80, c, now: end)
        XCTAssertEqual(o.mode, "normal")
        XCTAssertEqual(s.calStep, 0)
        XCTAssertEqual(s.lastCalibration, end)
        XCTAssertTrue(o.adapter)
    }

    func testCalibrationCancel() {
        var s = ChargeState()
        var c = cfg()
        step(&s, 50, c)
        c.commandId = 1; c.command = .calibrate
        step(&s, 50, c)
        c.commandId = 2; c.command = .cancel
        XCTAssertEqual(step(&s, 50, c).mode, "normal")
    }

    func testScheduleFiresOnceAndOverridesLimit() {
        var s = ChargeState()
        let task = ScheduleTask(action: .setLimit, value: 60, minute: 9 * 60)
        let c = cfg { $0.tasks = [task] }
        XCTAssertEqual(step(&s, 70, c, now: at(8, 59, 58)).status, "Charging to 80%")
        let o = step(&s, 70, c, now: at(9, 0, 2))
        XCTAssertEqual(o.limit, 60)
        XCTAssertEqual(o.status, "Holding at 60%")
        XCTAssertEqual(s.history.count, 1)
        step(&s, 70, c, now: at(9, 0, 4))
        XCTAssertEqual(s.history.count, 1)
        // the app changing the limit takes the override away
        var c2 = c
        c2.limit = 90
        XCTAssertEqual(step(&s, 70, c2, now: at(9, 0, 6)).limit, 90)
    }

    func testScheduleWeekdayAndActions() {
        var s = ChargeState()
        // 2026-11-14 is a Saturday (weekday 7)
        let weekdaysOnly = ScheduleTask(action: .topUp, value: 80, minute: 9 * 60, weekdays: [2, 3, 4, 5, 6])
        let c = cfg { $0.tasks = [weekdaysOnly] }
        step(&s, 70, c, now: at(8, 59, 58))
        XCTAssertEqual(step(&s, 70, c, now: at(9, 0, 2)).mode, "normal")
        let saturday = ScheduleTask(action: .topUp, value: 80, minute: 12 * 60, weekdays: [7])
        let c2 = cfg { $0.tasks = [saturday] }
        step(&s, 70, c2, now: at(11, 59, 58))
        XCTAssertEqual(step(&s, 70, c2, now: at(12, 0, 2)).mode, "topUp")
    }

    func testScheduleCatchUp() {
        let task = ScheduleTask(action: .setLimit, value: 60, minute: 9 * 60)
        var withCatchUp = ChargeState()
        let c = cfg { $0.tasks = [task]; $0.catchUp = true }
        step(&withCatchUp, 70, c, now: at(8, 0))
        XCTAssertEqual(step(&withCatchUp, 70, c, now: at(11, 0)).limit, 60)   // slept through 09:00

        var without = ChargeState()
        let n = cfg { $0.tasks = [task] }
        step(&without, 70, n, now: at(8, 0))
        XCTAssertEqual(step(&without, 70, n, now: at(11, 0)).limit, 80)

        var tooOld = ChargeState()
        step(&tooOld, 70, c, now: at(1, 0))
        XCTAssertEqual(step(&tooOld, 70, c, now: at(23, 0)).limit, 80)         // 22 h gap, older than 6 h
    }

    func testScheduleHistoryKeepsTwenty() {
        var s = ChargeState()
        let tasks = (0..<25).map { ScheduleTask(action: .setLimit, value: 50 + $0, minute: 9 * 60 + $0) }
        let c = cfg { $0.tasks = tasks; $0.catchUp = true }
        step(&s, 70, c, now: at(8, 0))
        step(&s, 70, c, now: at(11, 0))
        XCTAssertEqual(s.history.count, 20)
    }

    func testConfigClampingAndStrictDecoding() throws {
        var base = ChargeConfig()
        base.enabled = true
        base.tasks = [ScheduleTask(action: .setLimit, value: 5, minute: 5000, weekdays: [0, 3, 3, 9])]
        let data = try JSONEncoder().encode(base)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj["limit"] = 5
        obj["sailingRange"] = 99
        obj["heatThreshold"] = 10.0
        obj["sleepFloor"] = 1
        obj["somethingNew"] = "ignored"
        let c = ChargeConfig.decode(try JSONSerialization.data(withJSONObject: obj))
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.limit, 20)
        XCTAssertEqual(c.sailingRange, 20)
        XCTAssertEqual(c.heatThreshold, 30)
        XCTAssertEqual(c.sleepFloor, 5)
        XCTAssertEqual(c.tasks[0].value, 20)
        XCTAssertEqual(c.tasks[0].minute, 1439)
        XCTAssertEqual(c.tasks[0].weekdays, [3])
        obj["limit"] = 500
        XCTAssertEqual(ChargeConfig.decode(try JSONSerialization.data(withJSONObject: obj)).limit, 100)

        // wrong type, unknown enum value, garbage and missing data all fall back to "control off"
        obj["limit"] = "eighty"
        XCTAssertEqual(ChargeConfig.decode(try JSONSerialization.data(withJSONObject: obj)), .safe)
        obj["limit"] = 80
        obj["led"] = "rainbow"
        XCTAssertEqual(ChargeConfig.decode(try JSONSerialization.data(withJSONObject: obj)), .safe)
        XCTAssertEqual(ChargeConfig.decode(Data("not json".utf8)), .safe)
        XCTAssertEqual(ChargeConfig.decode(nil), .safe)
        XCTAssertFalse(ChargeConfig.safe.enabled)
    }

    func testLEDAndLowPower() {
        var s = ChargeState()
        let reflect = cfg { $0.led = .reflect }
        XCTAssertEqual(step(&s, 50, reflect).led, .orange)
        XCTAssertEqual(step(&s, 80, reflect).led, .green)
        let blink = cfg { $0.led = .blink; $0.autoDischarge = true }
        XCTAssertEqual(step(&s, 90, blink).led, .orangeBlink)
        XCTAssertEqual(step(&s, 90, cfg { $0.led = .off }).led, .off)
        XCTAssertNil(lowPowerFlags(.system))
        XCTAssertTrue(lowPowerFlags(.onBattery)!.battery)
        XCTAssertFalse(lowPowerFlags(.onBattery)!.adapter)
    }

    func testHistoryCappedAt48Hours() {
        var samples: [Sample] = []
        let now = Date()
        for minute in stride(from: 3000, through: 0, by: -1) {
            samples = appendSample(samples, Sample(t: now.addingTimeInterval(-Double(minute) * 60), pct: 50))
        }
        XCTAssertEqual(samples.count, 48 * 60 + 1)
    }

    func testInstallCommandQuoting() {
        XCTAssertEqual(shellQuote("a b'c"), "'a b'\\''c'")
        let cmd = installCommand(executable: "/Applications/I Z.app/Contents/MacOS/IzMac", uid: 501)
        XCTAssertTrue(cmd.contains("'/Applications/I Z.app/Contents/MacOS/IzMac'"))
        XCTAssertTrue(cmd.contains("launchctl bootstrap system"))
    }
}
