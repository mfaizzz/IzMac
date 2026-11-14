import AppKit
import Charts
import SwiftUI

@MainActor
enum MainWindow {
    private static var window: NSWindow?

    static func show(model: Model, charge: ChargeModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "IzMac"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: WindowRoot().environmentObject(model).environmentObject(charge))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum Page: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case chargeControl = "Charge Control"
    case sleep = "Sleep Behaviour"
    case energy = "Energy Use"
    case schedule = "Schedule"
    case appearance = "Appearance"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .chargeControl: return "battery.75percent"
        case .sleep: return "moon.zzz"
        case .energy: return "leaf"
        case .schedule: return "calendar"
        case .appearance: return "paintbrush"
        }
    }
}

struct WindowRoot: View {
    @State private var page: String? = Page.dashboard.rawValue

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in
                Label(p.rawValue, systemImage: p.icon)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            ScrollView {
                VStack(spacing: 10) {
                    switch Page(rawValue: page ?? "") ?? .dashboard {
                    case .dashboard: DashboardPage()
                    case .chargeControl: ChargeControlPage()
                    case .sleep: SleepPage()
                    case .energy: EnergyPage()
                    case .schedule: SchedulePage()
                    case .appearance: AppearancePage()
                    }
                }
                .padding(16)
                .font(.system(size: 12))
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .preferredColorScheme(.dark)
    }
}

// MARK: - shared pieces

struct HelperBanner: View {
    @EnvironmentObject var charge: ChargeModel

    var body: some View {
        if !charge.running {
            Card("Charge control", accent: .red) {
                primary("Not enabled")
                secondary("Needs your admin password once to install a small background helper.")
                Button(charge.installed ? "Reinstall charge control" : "Enable charge control") { charge.install() }
                    .disabled(charge.busy)
                if let e = charge.error { secondary(e) }
            }
        }
    }
}

private struct Point: Identifiable {
    let t: Date
    let v: Double
    var id: Date { t }
}

private struct LineChart: View {
    let points: [Point]
    let unit: String
    let color: Color
    var domain: ClosedRange<Double>?

    var body: some View {
        if points.count < 2 {
            secondary("Collecting data, one sample per minute.")
        } else {
            let lo = (points.map { $0.v }.min() ?? 0) - 1
            let hi = (points.map { $0.v }.max() ?? 1) + 1
            Chart(points) { p in
                LineMark(x: .value("Time", p.t), y: .value(unit, p.v)).foregroundStyle(color)
            }
            .chartYScale(domain: domain ?? (lo...hi))
            .frame(height: 120)
        }
    }
}

// MARK: - pages

struct DashboardPage: View {
    @EnvironmentObject var model: Model

    private var recent: [Sample] { model.history.filter { Date().timeIntervalSince($0.t) <= 86400 } }

    var body: some View {
        if let b = model.battery {
            Card("Battery", accent: .red) {
                primary("\(b.percent)% · \(b.state)")
                if let t = b.tempC { row("Temperature", String(format: "%.1f °C", t)) }
                if let p = b.powerW { row("Battery power", String(format: "%+.1f W", p)) }
                if let w = b.adapterWatts, w > 0 { row("Adapter", "\(w) W") }
            }
            Card("Health", accent: .green) {
                if let d = b.designMAh { row("Design capacity", "\(d) mAh") }
                if let m = b.maxMAh { row("Maximum capacity", "\(m) mAh" + (b.maxPercent.map { " (\($0)%)" } ?? "")) }
                if let c = b.cycles { row("Cycles", "\(c)") }
                row("Condition", b.condition)
            }
        } else {
            Card("Battery", accent: .red) { secondary("No battery found") }
        }
        Card("Battery level · 24 h", accent: .red) {
            LineChart(points: recent.map { Point(t: $0.t, v: $0.pct) }, unit: "%", color: .red, domain: 0...100)
        }
        Card("Temperature · 24 h", accent: .orange) {
            LineChart(points: recent.compactMap { s in s.temp.map { Point(t: s.t, v: $0) } }, unit: "°C", color: .orange)
        }
        Card("Power · 24 h", accent: .blue) {
            LineChart(points: recent.compactMap { s in s.power.map { Point(t: s.t, v: $0) } }, unit: "W", color: .blue)
        }
    }
}

struct ChargeControlPage: View {
    @EnvironmentObject var charge: ChargeModel

    private var calibrationText: String {
        let steps = ["", "Charging to 100%", "Discharging to 10%", "Charging to 100%", "Holding at 100% for 1 hour", "Discharging to the limit"]
        let n = charge.state?.calibrationStep ?? 0
        return n > 0 && n < steps.count ? "Step \(n) of 5: \(steps[n])" : "Not running"
    }

    var body: some View {
        HelperBanner()
        let s = charge.state
        VStack(spacing: 10) {
            Card("Charge control", accent: .red) {
                Toggle("Control charging", isOn: charge.bind(\.enabled)).toggleStyle(.switch)
                primary(s?.status ?? "")
                if let e = s?.lastError { secondary(e) }
                if let s, !s.supported.contains("chargeLimit") { secondary("This Mac does not expose the SMC keys needed for charge control.") }
            }
            Card("Charge limit", accent: .teal) {
                LimitSlider()
                Toggle("Sailing mode", isOn: charge.bind(\.sailing)).toggleStyle(.switch)
                if charge.config.sailing {
                    Stepper("Resume charging \(charge.config.sailingRange)% below the limit", value: charge.bind(\.sailingRange), in: 2...20)
                }
                Toggle("Automatic discharge above the limit", isOn: charge.bind(\.autoDischarge)).toggleStyle(.switch)
                    .disabled(!charge.has("discharge"))
                HStack {
                    Button(s?.mode == "discharge" ? "Stop discharge" : "Discharge") {
                        charge.send(s?.mode == "discharge" ? .cancel : .discharge)
                    }
                    .disabled(!charge.has("discharge"))
                    Button(s?.mode == "topUp" ? "Cancel top up" : "Top Up") {
                        charge.send(s?.mode == "topUp" ? .cancel : .topUp)
                    }
                }
            }
            Card("Heat protection", accent: .orange) {
                Toggle("Pause charging when the battery is hot", isOn: charge.bind(\.heatProtection)).toggleStyle(.switch)
                Stepper("Pause at \(Int(charge.config.heatThreshold)) °C, resume 2 °C lower",
                        value: charge.bind(\.heatThreshold), in: 30...45, step: 1)
                if let t = s?.temperature { secondary(String(format: "Now %.1f °C", t)) }
            }
            Card("Calibration", accent: .purple) {
                primary(calibrationText)
                secondary("Charge to 100%, discharge to 10%, charge to 100%, hold 1 hour, then discharge to the limit.")
                if let d = s?.lastCalibration { secondary("Last calibrated " + d.formatted(date: .abbreviated, time: .shortened)) }
                if (s?.calibrationStep ?? 0) > 0 {
                    Button("Cancel calibration") { charge.send(.cancel) }
                } else {
                    Button("Start calibration") { charge.send(.calibrate) }.disabled(!charge.has("discharge"))
                }
            }
        }
        .disabled(!charge.running)
        if charge.running, let s {
            Card("Helper", accent: .gray) {
                row("Version", s.helperVersion)
                row("SMC keys", s.keys.joined(separator: ", "))
                if charge.needsUpdate { Button("Update helper") { charge.install() }.disabled(charge.busy) }
                Button("Disable charge control") { charge.uninstall() }.disabled(charge.busy)
                if let e = charge.error { secondary(e) }
            }
        }
    }
}

struct SleepPage: View {
    @EnvironmentObject var charge: ChargeModel

    var body: some View {
        HelperBanner()
        Card("Sleep behaviour", accent: .indigo) {
            Toggle("Prevent sleep while charging to the limit", isOn: charge.bind(\.preventSleep)).toggleStyle(.switch)
            Stepper("Allow sleep again at \(charge.config.sleepFloor)% while discharging", value: charge.bind(\.sleepFloor), in: 5...50)
            Toggle("Stop charging before sleep", isOn: charge.bind(\.stopBeforeSleep)).toggleStyle(.switch)
            secondary("The helper stops charging just before sleep when the battery is at or above the limit, and re-checks on wake.")
        }
        .disabled(!charge.running)
    }
}

struct EnergyPage: View {
    @EnvironmentObject var charge: ChargeModel

    var body: some View {
        HelperBanner()
        Card("Low Power Mode", accent: .yellow) {
            Picker("Low Power Mode", selection: charge.bind(\.lowPower)) {
                ForEach(LowPowerSetting.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            secondary("Applied by the helper with pmset, only when you change the setting.")
        }
        .disabled(!charge.running)
    }
}

struct SchedulePage: View {
    @EnvironmentObject var charge: ChargeModel
    @State private var action = ChargeAction.setLimit
    @State private var value = 80
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var days: Set<Int> = Set(1...7)

    private func describe(_ t: ScheduleTask) -> String {
        let when = String(format: "%02d:%02d", t.minute / 60, t.minute % 60)
        let symbols = Calendar.current.shortWeekdaySymbols
        let d = t.weekdays.count == 7 ? "every day" : t.weekdays.map { symbols[$0 - 1] }.joined(separator: " ")
        return "\(when), \(d)"
    }

    var body: some View {
        HelperBanner()
        VStack(spacing: 10) {
            Card("Tasks", accent: .teal) {
                if charge.config.tasks.isEmpty { secondary("No tasks yet") }
                ForEach(charge.config.tasks) { t in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            primary(t.title)
                            secondary(describe(t))
                        }
                        Spacer()
                        Button { charge.update { $0.tasks.removeAll { $0.id == t.id } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Toggle("Catch up on tasks missed while asleep (last 6 hours)", isOn: charge.bind(\.catchUp)).toggleStyle(.switch)
            }
            Card("Add task", accent: .blue) {
                Picker("Action", selection: $action) {
                    ForEach(ChargeAction.allCases.filter { $0 != .cancel }, id: \.self) { a in
                        Text(ScheduleTask(action: a, value: value).title).tag(a)
                    }
                }
                if action == .setLimit { Stepper("Limit \(value)%", value: $value, in: 20...100) }
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                HStack {
                    ForEach(1...7, id: \.self) { d in
                        Toggle(Calendar.current.shortWeekdaySymbols[d - 1], isOn: Binding(
                            get: { days.contains(d) },
                            set: { on in if on { days.insert(d) } else { days.remove(d) } }
                        ))
                        .toggleStyle(.button)
                    }
                }
                Button("Add task") {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                    let task = ScheduleTask(action: action, value: value, minute: (c.hour ?? 0) * 60 + (c.minute ?? 0),
                                            weekdays: days.sorted())
                    charge.update { $0.tasks.append(task) }
                }
                .disabled(days.isEmpty || charge.config.tasks.count >= 50)
            }
            Card("History", accent: .gray) {
                let runs = Array((charge.state?.history ?? []).reversed())
                if runs.isEmpty { secondary("Nothing has run yet") }
                ForEach(Array(runs.enumerated()), id: \.offset) { _, r in
                    row(r.text, r.date.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
        .disabled(!charge.running)
    }
}

struct AppearancePage: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var charge: ChargeModel
    @AppStorage("showCodex") private var showCodex = true
    @AppStorage("showClaude") private var showClaude = true
    @AppStorage("showPrayer") private var showPrayer = true
    @AppStorage("showBattery") private var showBattery = false

    var body: some View {
        Card("Menu bar", accent: .teal) {
            Toggle("Battery %", isOn: $showBattery).toggleStyle(.switch)
            Toggle("Codex %", isOn: $showCodex).toggleStyle(.switch)
            Toggle("Claude %", isOn: $showClaude).toggleStyle(.switch)
            Toggle("Next prayer", isOn: $showPrayer).toggleStyle(.switch)
        }
        Card("MagSafe LED", accent: .green) {
            Picker("MagSafe LED", selection: charge.bind(\.led)) {
                ForEach(LEDSetting.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(!charge.running || !charge.has("magsafeLED"))
            if charge.running && !charge.has("magsafeLED") { secondary("This Mac has no controllable MagSafe LED.") }
            if !charge.running { secondary("Enable charge control to use this.") }
        }
        Card("General", accent: .gray) {
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
        }
    }
}
