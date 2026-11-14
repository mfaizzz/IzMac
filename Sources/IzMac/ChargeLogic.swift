import Foundation

// Pure charge-control logic (Foundation only). The root daemon feeds it readings and applies its outputs.

let appVersion = "0.2.0"

enum LEDSetting: String, Codable, CaseIterable {
    case system, reflect, blink, off
    var title: String {
        switch self {
        case .system: return "System"
        case .reflect: return "Reflect charge limit"
        case .blink: return "Reflect limit, blink while discharging"
        case .off: return "Off"
        }
    }
}

/// ACLC values: 0x00 system, 0x01 off, 0x03 green, 0x04 orange, 0x06 orange slow blink.
enum LEDColor: UInt8, Equatable {
    case system = 0x00, off = 0x01, green = 0x03, orange = 0x04, orangeBlink = 0x06
}

enum LowPowerSetting: String, Codable, CaseIterable {
    case system, never, always, onBattery, onAdapter
    var title: String {
        switch self {
        case .system: return "Leave to macOS"
        case .never: return "Never"
        case .always: return "Always"
        case .onBattery: return "Only on battery"
        case .onAdapter: return "Only on power adapter"
        }
    }
}

/// pmset flags (-b battery, -c charger); nil means do not touch.
func lowPowerFlags(_ s: LowPowerSetting) -> (battery: Bool, adapter: Bool)? {
    switch s {
    case .system: return nil
    case .never: return (false, false)
    case .always: return (true, true)
    case .onBattery: return (true, false)
    case .onAdapter: return (false, true)
    }
}

enum ChargeAction: String, Codable, CaseIterable {
    case setLimit, topUp, discharge, calibrate, cancel
}

struct ScheduleTask: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var action: ChargeAction = .setLimit
    var value: Int = 80
    var minute: Int = 9 * 60          // minutes since midnight
    var weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]   // Calendar weekday, 1 = Sunday

    var title: String {
        switch action {
        case .setLimit: return "Set limit \(value)%"
        case .topUp: return "Top Up"
        case .discharge: return "Start discharge"
        case .calibrate: return "Start calibration"
        case .cancel: return "Cancel"
        }
    }
}

struct TaskRun: Codable, Equatable {
    var date: Date
    var text: String
}

/// App -> daemon. Decoded strictly (any type mismatch or missing field fails), then clamped.
struct ChargeConfig: Codable, Equatable {
    var enabled = false
    var limit = 80
    var sailing = false
    var sailingRange = 5
    var autoDischarge = false
    var heatProtection = false
    var heatThreshold = 35.0
    var stopBeforeSleep = false
    var preventSleep = false
    var sleepFloor = 20
    var led = LEDSetting.system
    var lowPower = LowPowerSetting.system
    var catchUp = false
    var tasks: [ScheduleTask] = []
    var commandId = 0
    var command: ChargeAction?

    /// Control off: charging enabled, adapter enabled, LED to the system.
    static let safe = ChargeConfig()

    func clamped() -> ChargeConfig {
        var c = self
        c.limit = min(max(limit, 20), 100)
        c.sailingRange = min(max(sailingRange, 2), 20)
        c.heatThreshold = heatThreshold.isFinite ? min(max(heatThreshold, 30), 45) : 35
        c.sleepFloor = min(max(sleepFloor, 5), 50)
        c.commandId = max(commandId, 0)
        c.tasks = tasks.prefix(50).map { t in
            var t = t
            t.value = min(max(t.value, 20), 100)
            t.minute = min(max(t.minute, 0), 1439)
            t.weekdays = Array(Set(t.weekdays.filter { (1...7).contains($0) })).sorted()
            return t
        }
        return c
    }

    static func decode(_ data: Data?) -> ChargeConfig {
        guard let data, data.count < 65536,
              let c = try? JSONDecoder().decode(ChargeConfig.self, from: data) else { return .safe }
        return c.clamped()
    }
}

/// Daemon -> app (state.json).
struct DaemonState: Codable, Equatable {
    var helperVersion = appVersion
    var supported: [String] = []
    var keys: [String] = []
    var mode = "off"
    var status = ""
    var charging: Bool?
    var adapter: Bool?
    var pluggedIn = false
    var percent = 0
    var temperature: Double?
    var limit = 80
    var target = 80
    var lastError: String?
    var calibrationStep = 0
    var lastCalibration: Date?
    var history: [TaskRun] = []
    var updated = Date(timeIntervalSince1970: 0)
}

struct ChargeState: Equatable {
    var holding = false
    var topUp = false
    var discharge = false
    var heatPaused = false
    var calStep = 0               // 0 none, 1 charge to 100, 2 discharge to 10, 3 charge to 100, 4 hold 1 h, 5 discharge to limit
    var calHoldStart: Date?
    var lastCalibration: Date?
    var limitOverride: Int?       // set by a scheduled "set limit"; cleared when the app changes the limit
    var seenLimit: Int?
    var seenCommand: Int?
    var lastEval: Date?
    var history: [TaskRun] = []
}

struct ChargeInput {
    var percent: Int
    var plugged: Bool
    var tempC: Double?
    var now: Date
    var canDischarge = true
    var cfg: ChargeConfig
}

struct ChargeOutput: Equatable {
    var charging: Bool
    var adapter: Bool
    var led: LEDColor
    var status: String
    var mode: String
    var limit: Int
    var target: Int
}

/// Tasks whose time of day falls in (from, to] on a matching weekday, in time order.
func dueTasks(_ tasks: [ScheduleTask], from: Date, to: Date, calendar: Calendar) -> [ScheduleTask] {
    let from = max(from, to.addingTimeInterval(-7 * 86400))
    guard to > from else { return [] }
    var hits: [(Date, ScheduleTask)] = []
    var day = calendar.startOfDay(for: from)
    while day <= to {
        let weekday = calendar.component(.weekday, from: day)
        for t in tasks where t.weekdays.contains(weekday) {
            if let at = calendar.date(byAdding: .minute, value: t.minute, to: day), at > from, at <= to {
                hits.append((at, t))
            }
        }
        guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
    }
    return hits.sorted { $0.0 < $1.0 }.map { $0.1 }
}

func chargeStep(_ input: ChargeInput, _ prev: ChargeState, calendar: Calendar = .current) -> (ChargeOutput, ChargeState) {
    let cfg = input.cfg.clamped()
    let now = input.now
    let pct = min(max(input.percent, 0), 100)

    guard cfg.enabled else {
        var fresh = ChargeState()
        fresh.lastEval = now
        fresh.seenCommand = cfg.commandId
        fresh.history = prev.history
        fresh.lastCalibration = prev.lastCalibration
        let out = ChargeOutput(charging: true, adapter: true, led: .system, status: "Charge control off",
                               mode: "off", limit: cfg.limit, target: cfg.limit)
        return (out, fresh)
    }

    var s = prev
    let last = s.lastEval ?? now
    s.lastEval = now
    if cfg.limit != s.seenLimit { s.limitOverride = nil; s.seenLimit = cfg.limit }

    func run(_ action: ChargeAction, _ value: Int, _ label: String) {
        switch action {
        case .setLimit: s.limitOverride = value
        case .topUp: s.topUp = true; s.discharge = false
        case .discharge: s.discharge = true; s.topUp = false
        case .calibrate: s.calStep = 1; s.calHoldStart = nil; s.topUp = false; s.discharge = false
        case .cancel: s.topUp = false; s.discharge = false; s.calStep = 0; s.calHoldStart = nil
        }
        if !label.isEmpty {
            s.history.append(TaskRun(date: now, text: label))
            if s.history.count > 20 { s.history.removeFirst(s.history.count - 20) }
        }
    }

    // Scheduled tasks. After a gap (sleep) only catch-up mode looks back, at most 6 hours.
    let gap = now.timeIntervalSince(last)
    let from = gap <= 120 ? last : (cfg.catchUp ? max(last, now.addingTimeInterval(-6 * 3600)) : now)
    for t in dueTasks(cfg.tasks, from: from, to: now, calendar: calendar) { run(t.action, t.value, t.title) }

    // One-shot command from the app.
    if let seen = s.seenCommand {
        if cfg.commandId != seen {
            s.seenCommand = cfg.commandId
            if let c = cfg.command { run(c, 0, "") }
        }
    } else {
        s.seenCommand = cfg.commandId
    }

    let limit = s.limitOverride ?? cfg.limit
    if !input.plugged { s.topUp = false; s.discharge = false }
    if pct >= 100 { s.topUp = false }
    if pct <= limit { s.discharge = false }

    switch s.calStep {
    case 1: if pct >= 100 { s.calStep = 2 }
    case 2: if pct <= 10 { s.calStep = 3 }
    case 3: if pct >= 100 { s.calStep = 4; s.calHoldStart = now }
    case 4: if let h = s.calHoldStart, now.timeIntervalSince(h) >= 3600 { s.calStep = 5 }
    case 5: if pct <= limit { s.calStep = 0; s.lastCalibration = now; s.calHoldStart = nil }
    default: break
    }

    let calCharging = s.calStep == 1 || s.calStep == 3 || s.calStep == 4
    let calDischarging = s.calStep == 2 || (s.calStep == 5 && pct > limit)
    let autoDischarge = cfg.autoDischarge && input.plugged && s.calStep == 0 && !s.topUp && pct > limit
    // Never force-discharge at or below 10 %.
    let discharging = input.canDischarge && pct > 10 && (calDischarging || s.discharge || autoDischarge)

    let forced = s.topUp || calCharging
    let target = forced ? 100 : limit
    if forced {
        s.holding = false
    } else if pct >= target {
        s.holding = true
    } else if pct <= target - (cfg.sailing ? cfg.sailingRange : 1) {
        s.holding = false
    }

    if cfg.heatProtection, let t = input.tempC {
        if t >= cfg.heatThreshold { s.heatPaused = true } else if t <= cfg.heatThreshold - 2 { s.heatPaused = false }
    } else {
        s.heatPaused = false
    }

    let charging = !discharging && !s.holding && !s.heatPaused

    let led: LEDColor
    switch cfg.led {
    case .system: led = .system
    case .off: led = .off
    case .reflect, .blink:
        if discharging { led = cfg.led == .blink ? .orangeBlink : .system }
        else if !input.plugged { led = .system }
        else { led = charging ? .orange : .green }
    }

    let status: String
    let mode: String
    if s.calStep > 0 { mode = "calibrating" } else if discharging { mode = "discharge" } else if s.topUp { mode = "topUp" } else { mode = "normal" }
    if s.heatPaused { status = "Heat protection: paused" }
    else if s.calStep > 0 { status = "Calibrating: step \(s.calStep) of 5" }
    else if discharging { status = "Discharging to \(limit)%" }
    else if s.topUp { status = "Topping up to 100%" }
    else if !input.plugged { status = "On battery" }
    else if s.holding { status = "Holding at \(limit)%" }
    else { status = "Charging to \(limit)%" }

    return (ChargeOutput(charging: charging, adapter: !discharging, led: led, status: status, mode: mode, limit: limit, target: target), s)
}

// MARK: - History samples (dashboard charts)

struct Sample: Codable, Equatable, Identifiable {
    var t: Date
    var pct: Double
    var temp: Double?
    var power: Double?
    var id: Date { t }
}

func appendSample(_ samples: [Sample], _ s: Sample, keep: TimeInterval = 48 * 3600) -> [Sample] {
    (samples + [s]).filter { s.t.timeIntervalSince($0.t) <= keep }
}
