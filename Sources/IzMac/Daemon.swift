import Foundation
import IOKit
import IOKit.pwr_mgt

enum HelperPaths {
    static let label = "my.mfaizzz.izmac.helper"
    static let binary = "/Library/PrivilegedHelperTools/my.mfaizzz.izmac.helper"
    static let plist = "/Library/LaunchDaemons/my.mfaizzz.izmac.helper.plist"
    static let support = "/Library/Application Support/IzMac"
    static let config = support + "/config.json"
    static let state = support + "/state.json"
    static let log = "/Library/Logs/IzMac-helper.log"
}

private var theDaemon: Daemon?

private func powerCallback(_ refcon: UnsafeMutableRawPointer?, _ service: io_service_t, _ type: UInt32, _ arg: UnsafeMutableRawPointer?) {
    guard let d = theDaemon else { return }
    switch type {
    case 0xE000_0270:   // kIOMessageCanSystemSleep
        IOAllowPowerChange(d.powerPort, Int(bitPattern: arg))
    case 0xE000_0280:   // kIOMessageSystemWillSleep
        d.willSleep()
        IOAllowPowerChange(d.powerPort, Int(bitPattern: arg))
    case 0xE000_0300:   // kIOMessageSystemHasPoweredOn
        d.didWake()
    default: break
    }
}

/// Runs as root via launchd: `IzMac --daemon`.
final class Daemon {
    private let smc = SMCClient()
    private var chargeGroup: [SMCControl]?
    private var adapterGroup: [SMCControl]?
    private var hasLED = false
    private var cfg = ChargeConfig.safe
    private var state = ChargeState()
    private var lastPlugged = false
    private var lastPercent = 100
    private var lastOut: ChargeOutput?
    private var lastLED: LEDColor?
    private var lastLowPower: LowPowerSetting?
    private var lastWritten: DaemonState?
    private var lastLogged = ""
    private var lastError: String?
    private var lastConfigProblem = false
    var powerPort: io_connect_t = 0

    init() {
        if let smc {
            chargeGroup = chargeGroups.first { g in g.allSatisfy { smc.size($0.key) == $0.size } }
            adapterGroup = adapterGroups.first { g in g.allSatisfy { smc.size($0.key) == $0.size } }
            hasLED = smc.size(ledKey) == 1
        }
    }

    // MARK: lifecycle

    func run() -> Never {
        theDaemon = self
        log("started v\(appVersion) charge=\(chargeGroup?.map { $0.key }.joined(separator: "+") ?? "none") adapter=\(adapterGroup?.first?.key ?? "none") led=\(hasLED)")
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [self] in
                log("stopping on signal \(sig), restoring normal charging")
                restore()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        powerPort = IORegisterForSystemPower(nil, &port, powerCallback, &notifier)
        if let port {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        }
        tick()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [self] _ in tick() }
        RunLoop.main.run()
        exit(0)
    }

    private var signalSources: [DispatchSourceSignal] = []

    /// Charging on, adapter on, LED to the system. Writes only keys that exist.
    func restore() {
        if let g = chargeGroup { set(g, on: true) }
        if let g = adapterGroup { set(g, on: true) }
        if hasLED { _ = smc?.write(ledKey, [LEDColor.system.rawValue], verify: false) }
    }

    func willSleep() {
        guard cfg.enabled, cfg.stopBeforeSleep, lastPlugged, let g = chargeGroup,
              let out = lastOut, lastPercent >= out.target else { return }
        log("stopping charge before sleep at \(lastPercent)%")
        set(g, on: false)
    }

    func didWake() {
        lastLED = nil
        DispatchQueue.main.async { [self] in tick() }
    }

    // MARK: SMC helpers

    private func isOn(_ g: [SMCControl]) -> Bool? {
        guard let smc else { return nil }
        var all = true
        for c in g {
            guard let v = smc.read(c.key) else { return nil }
            if v != c.on { all = false }
        }
        return all
    }

    private func set(_ g: [SMCControl], on: Bool) {
        guard let smc else { return }
        for c in g {
            if !smc.write(c.key, on ? c.on : c.off) {
                lastError = "SMC write failed: \(c.key)"
                log(lastError ?? "")
            }
        }
    }

    private func pluggedSignal(_ b: BatteryInfo) -> Bool {
        if b.plugged { return true }
        if let v = smc?.read(acPowerKey), v.count == 1, Int8(bitPattern: v[0]) > 0 { return true }
        return false
    }

    // MARK: tick

    private func readConfig() -> ChargeConfig {
        var st = stat()
        let ok = lstat(HelperPaths.config, &st) == 0 && (st.st_mode & 0o170000) == 0o100000 && st.st_size < 65536
        guard ok, let data = FileManager.default.contents(atPath: HelperPaths.config) else {
            noteConfig(problem: false)   // a missing file is the normal "never configured" case
            return .safe
        }
        guard (try? JSONDecoder().decode(ChargeConfig.self, from: data)) != nil else {
            noteConfig(problem: true)
            return .safe
        }
        noteConfig(problem: false)
        return ChargeConfig.decode(data)
    }

    private func noteConfig(problem: Bool) {
        if problem != lastConfigProblem {
            lastConfigProblem = problem
            log(problem ? "config.json is invalid, using safe defaults" : "config.json OK")
        }
    }

    private func tick() {
        cfg = readConfig()
        guard let b = readBattery() else {
            lastError = "Battery not readable"
            apply(ChargeOutput(charging: true, adapter: true, led: .system, status: "Battery not readable",
                               mode: "off", limit: cfg.limit, target: cfg.limit))
            publish(nil, nil)
            return
        }
        var plugged = pluggedSignal(b)
        // With the adapter disabled macOS may report "not plugged in"; keep believing the last known state.
        if !plugged, let g = adapterGroup, isOn(g) == false, lastPlugged { plugged = true }
        lastPlugged = plugged
        lastPercent = b.percent

        let canDischarge = chargeGroup != nil && adapterGroup != nil
        let (out, next) = chargeStep(ChargeInput(percent: b.percent, plugged: plugged, tempC: b.tempC, now: Date(),
                                                 canDischarge: canDischarge, cfg: cfg), state)
        state = next
        lastOut = out
        apply(out)
        applyLowPower()
        publish(b, out)
    }

    private func apply(_ out: ChargeOutput) {
        if let g = chargeGroup, isOn(g) != out.charging { set(g, on: out.charging) }
        if let g = adapterGroup, isOn(g) != out.adapter { set(g, on: out.adapter) }
        if hasLED, lastLED != out.led {
            lastLED = out.led
            _ = smc?.write(ledKey, [out.led.rawValue], verify: false)
        }
        let line = "\(out.mode) charging=\(out.charging) adapter=\(out.adapter) led=\(out.led) \(out.status)"
        if line != lastLogged { lastLogged = line; log(line) }
    }

    private func applyLowPower() {
        guard cfg.lowPower != lastLowPower else { return }
        lastLowPower = cfg.lowPower
        guard let f = lowPowerFlags(cfg.lowPower) else { return }
        for (flag, on) in [("-b", f.battery), ("-c", f.adapter)] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = [flag, "lowpowermode", on ? "1" : "0"]
            do { try p.run(); p.waitUntilExit() } catch { lastError = "pmset failed" }
        }
        log("low power mode: \(cfg.lowPower.rawValue)")
    }

    private func publish(_ b: BatteryInfo?, _ out: ChargeOutput?) {
        var s = DaemonState()
        s.supported = []
        if chargeGroup != nil { s.supported.append("chargeLimit") }
        if chargeGroup != nil && adapterGroup != nil { s.supported.append("discharge") }
        if hasLED { s.supported.append("magsafeLED") }
        s.keys = (chargeGroup ?? []).map { $0.key } + (adapterGroup ?? []).map { $0.key } + (hasLED ? [ledKey] : [])
        s.mode = out?.mode ?? "off"
        s.status = chargeGroup == nil ? "Charge control is not supported on this Mac" : (out?.status ?? "Battery not readable")
        s.charging = chargeGroup.flatMap { isOn($0) }
        s.adapter = adapterGroup.flatMap { isOn($0) }
        s.pluggedIn = lastPlugged
        s.percent = b?.percent ?? 0
        s.temperature = b?.tempC
        s.limit = out?.limit ?? cfg.limit
        s.target = out?.target ?? cfg.limit
        s.lastError = lastError
        s.calibrationStep = state.calStep
        s.lastCalibration = state.lastCalibration
        s.history = state.history
        let now = Date()
        s.updated = now
        if let w = lastWritten {
            var same = s
            same.updated = w.updated
            if same == w && now.timeIntervalSince(w.updated) < 10 { return }
        }
        guard let data = try? JSONEncoder.state.encode(s) else { return }
        // Atomic: temp file + rename, so a planted symlink at state.json is replaced, never followed.
        if (try? data.write(to: URL(fileURLWithPath: HelperPaths.state), options: .atomic)) != nil { lastWritten = s }
    }

    // MARK: log

    func log(_ msg: String) {
        let path = HelperPaths.log
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        }
        let line = "\(Date().formatted(.iso8601)) \(msg)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o644])
        }
    }
}

extension JSONEncoder {
    static var state: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var state: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

func runDaemon() -> Never {
    Daemon().run()
}

/// `IzMac --restore`: put charging, adapter and LED back to normal and exit (used by uninstall).
func runRestore() -> Never {
    let d = Daemon()
    d.restore()
    exit(0)
}
