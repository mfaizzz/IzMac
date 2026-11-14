import Foundation
import IOKit.pwr_mgt
import SwiftUI

// App side of charge control: install/uninstall the root helper, write config.json, read state.json.

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func helperPlist() -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(HelperPaths.label)</string>
        <key>ProgramArguments</key>
        <array><string>\(HelperPaths.binary)</string><string>--daemon</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
    </dict>
    </plist>
    """
}

/// One shell line, run as root. The helper is copied out of the (user-writable) app bundle.
func installCommand(executable: String, uid: UInt32) -> String {
    let q = shellQuote
    let b64 = Data(helperPlist().utf8).base64EncodedString()
    return [
        "/bin/launchctl bootout system/\(HelperPaths.label) 2>/dev/null || true",
        "/bin/mkdir -p /Library/PrivilegedHelperTools",
        "/usr/bin/install -m 755 -o root -g wheel \(q(executable)) \(q(HelperPaths.binary))",
        "/bin/mkdir -p \(q(HelperPaths.support))",
        "/usr/sbin/chown \(uid):wheel \(q(HelperPaths.support))",
        "/bin/chmod 755 \(q(HelperPaths.support))",
        "echo \(b64) | /usr/bin/base64 -D > \(q(HelperPaths.plist))",
        "/usr/sbin/chown root:wheel \(q(HelperPaths.plist))",
        "/bin/chmod 644 \(q(HelperPaths.plist))",
        "/bin/launchctl bootstrap system \(q(HelperPaths.plist))",
    ].joined(separator: " && ")
}

func uninstallCommand() -> String {
    let q = shellQuote
    return [
        "\(q(HelperPaths.binary)) --restore || true",
        "/bin/launchctl bootout system/\(HelperPaths.label) 2>/dev/null || true",
        "/bin/rm -f \(q(HelperPaths.plist)) \(q(HelperPaths.binary))",
        "/bin/rm -rf \(q(HelperPaths.support))",
    ].joined(separator: "; ")
}

/// Runs a shell command as root through the system password prompt. Returns an error message or nil.
func runAsAdmin(_ command: String, prompt: String) -> String? {
    let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    let script = "do shell script \"\(esc(command))\" with prompt \"\(esc(prompt))\" with administrator privileges"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    do { try p.run() } catch { return "Could not run osascript" }
    let data = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus == 0 { return nil }
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.contains("-128") ? "Cancelled" : (text.isEmpty ? "Install failed" : text)
}

@MainActor
final class ChargeModel: ObservableObject {
    @Published var config = ChargeConfig()
    @Published var state: DaemonState?
    @Published var busy = false
    @Published var error: String?
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    init() {
        if let d = FileManager.default.contents(atPath: HelperPaths.config),
           let c = try? JSONDecoder().decode(ChargeConfig.self, from: d) {
            config = c.clamped()
        }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    var installed: Bool { FileManager.default.fileExists(atPath: HelperPaths.plist) }
    var running: Bool { state.map { Date().timeIntervalSince($0.updated) < 15 } ?? false }
    var needsUpdate: Bool { running && state?.helperVersion != appVersion }
    var supported: Bool { state?.supported.contains("chargeLimit") ?? false }
    func has(_ feature: String) -> Bool { state?.supported.contains(feature) ?? false }

    func poll() {
        if let d = FileManager.default.contents(atPath: HelperPaths.state),
           let s = try? JSONDecoder.state.decode(DaemonState.self, from: d) {
            if s != state { state = s }
        } else if state != nil {
            state = nil
        }
        updateAssertion()
    }

    func save() {
        guard let d = try? JSONEncoder.state.encode(config) else { return }
        try? d.write(to: URL(fileURLWithPath: HelperPaths.config), options: .atomic)
    }

    func update(_ f: (inout ChargeConfig) -> Void) {
        f(&config)
        save()
    }

    func bind<T>(_ kp: WritableKeyPath<ChargeConfig, T>) -> Binding<T> {
        Binding(get: { self.config[keyPath: kp] }, set: { v in self.update { $0[keyPath: kp] = v } })
    }

    func send(_ a: ChargeAction) {
        update { $0.commandId += 1; $0.command = a }
    }

    func install() {
        guard let exe = Bundle.main.executablePath else { error = "Cannot find the app executable"; return }
        let cmd = installCommand(executable: exe, uid: getuid())
        busy = true
        error = nil
        Task {
            let err = await Task.detached { runAsAdmin(cmd, prompt: "IzMac needs to install its charge control helper.") }.value
            busy = false
            error = err
            if err == nil { update { $0.enabled = true } }
            poll()
        }
    }

    func uninstall() {
        busy = true
        error = nil
        Task {
            let err = await Task.detached { runAsAdmin(uninstallCommand(), prompt: "IzMac needs to remove its charge control helper.") }.value
            busy = false
            error = err
            if err == nil { state = nil; updateAssertion() }
        }
    }

    /// Hold a no-idle-sleep assertion while charging below the target, or while discharging above the sleep floor.
    private func updateAssertion() {
        var want = false
        if let s = state, running, config.enabled, config.preventSleep {
            let charging = s.charging == true && s.pluggedIn && s.percent < s.target
            let discharging = s.adapter == false && s.percent > config.sleepFloor
            want = charging || discharging
        }
        if want && assertion == 0 {
            IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(255),
                                        "IzMac: charging to the limit" as CFString, &assertion)
        } else if !want && assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
