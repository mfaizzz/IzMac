import AppKit
import SwiftUI

struct Card<Content: View>: View {
    let title: String
    let accent: Color
    let content: Content

    init(_ title: String, accent: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.gray)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.leading, 17)
        .padding(.trailing, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) { accent.frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private func primary(_ s: String) -> some View {
    Text(s).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
}

private func secondary(_ s: String) -> some View {
    Text(s).font(.system(size: 12)).foregroundStyle(.gray)
}

private func row(_ label: String, _ value: String) -> some View {
    HStack {
        Text(label).foregroundStyle(.gray)
        Spacer()
        Text(value).foregroundStyle(.white).fontWeight(.semibold)
    }
    .font(.system(size: 12))
}

struct RootView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 10) {
            reflection
            solat
            codex
            claude
            battery
            footer
        }
        .padding(12)
        .frame(width: 380)
        .preferredColorScheme(.dark)
        .onAppear { model.opened() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.opened()
        }
    }

    var reflection: some View {
        Card("A moment of reflection", accent: .teal) {
            primary(model.quote).fixedSize(horizontal: false, vertical: true)
        }
    }

    var solat: some View {
        Card("Waktu solat", accent: .green) {
            if let s = model.solat {
                let day = model.today
                primary(s.zone ?? "WLY01")
                if let h = day?.hijri { secondary(hijriText(h)) }
                if let n = model.next {
                    Text("\(n.name) in \(countdownText(from: model.now, to: n.date))")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                }
                if let day {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 3) {
                        ForEach(day.times, id: \.name) { t in
                            let isNext = t == model.next
                            HStack {
                                Text(t.name)
                                Spacer()
                                Text(timeText(t.date))
                            }
                            .font(.system(size: 12, weight: isNext ? .bold : .regular))
                            .foregroundStyle(isNext ? Color.green : Color.white)
                        }
                    }
                } else {
                    secondary("No times for today")
                }
            } else {
                secondary("Loading prayer times...")
            }
        }
    }

    var codex: some View {
        Card("Codex usage", accent: .blue) {
            if let c = model.codex {
                ForEach(Array(c.windows.enumerated()), id: \.offset) { _, w in
                    primary("\(windowLabel(w.minutes)): \(w.remaining)% remaining")
                    if let r = w.resets { secondary(resetText(r)) }
                }
                VStack(spacing: 2) {
                    if let t = c.lifetimeTokens { row("All-time tokens", tokenText(t)) }
                    if let t = c.peakDailyTokens { row("Peak daily tokens", tokenText(t)) }
                    if let d = c.latestLabel, let t = c.latestTokens { row("\(d):", "\(tokenText(t)) tokens") }
                }
                .padding(.top, 2)
                if let n = c.note { secondary(n) }
                if let u = c.updated {
                    Text("Updated \(timeText(u))").font(.system(size: 10)).foregroundStyle(.gray)
                }
            } else {
                secondary(model.codexMessage ?? "No Codex data")
            }
        }
    }

    var claude: some View {
        Card("Claude usage", accent: .orange) {
            if let c = model.claude {
                if let f = c.five {
                    primary("5h: \(f.remaining)% remaining")
                    if let r = f.resets { secondary(resetText(r)) }
                }
                if let w = c.week {
                    primary("Week: \(w.remaining)% remaining")
                    if let r = w.resets { secondary(resetText(r)) }
                }
            } else {
                secondary(model.claudeMessage ?? "Claude usage unavailable")
            }
        }
    }

    var battery: some View {
        Card("Battery", accent: .red) {
            if let b = model.battery {
                primary("\(b.percent)% · \(b.state)")
                secondary(capacityText(b))
                secondary(conditionText(b))
            } else {
                secondary("No battery found")
            }
        }
    }

    var footer: some View {
        VStack(spacing: 6) {
            HStack {
                Button("Refresh now") { model.refresh(force: true) }.keyboardShortcut("r")
                Spacer()
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button("Quit IzMac") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .font(.system(size: 12))
    }
}

private func capacityText(_ b: BatteryInfo) -> String {
    guard let m = b.maxPercent else { return "Max capacity unavailable" }
    if let a = b.maxMAh, let d = b.designMAh { return "Max capacity \(m)% (\(a) / \(d) mAh)" }
    return "Max capacity \(m)%"
}

private func conditionText(_ b: BatteryInfo) -> String {
    var parts: [String] = []
    if let c = b.cycles { parts.append("Cycles \(c)") }
    parts.append("Condition \(b.condition)")
    if let t = b.tempC { parts.append(String(format: "%.1f °C", t)) }
    return parts.joined(separator: " · ")
}
