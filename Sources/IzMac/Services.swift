import CoreLocation
import Foundation
import IOKit
import Security

// MARK: - Claude OAuth token (never logged, never persisted)

func readClaudeToken() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
       let data = out as? Data, let token = parseClaudeToken(data) {
        return token
    }
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    return (try? Data(contentsOf: file)).flatMap(parseClaudeToken)
}

// MARK: - Codex app-server (blocking; call off the main thread)

func codexBinaryPath() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Returns (snapshot, nil) or (nil, error message). Gives up after `timeout` seconds and always stops the child.
func runCodexAppServer(path: String, timeout: TimeInterval = 35) -> (CodexSnapshot?, String?) {
    signal(SIGPIPE, SIG_IGN)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = ["app-server", "--stdio"]
    let inPipe = Pipe()
    let outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (nil, "Could not start Codex app-server") }
    defer {
        try? inPipe.fileHandleForWriting.close()
        if p.isRunning {
            p.terminate()
            for _ in 0..<20 where p.isRunning { usleep(100_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
    }
    // Terminating the child closes its stdout, which ends the blocking read below.
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if p.isRunning { p.terminate() }
    }
    func send(_ line: String) {
        try? inPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }
    send(codexHello)
    var state = CodexRPC()
    var buf = Data()
    read: while true {
        let chunk = outPipe.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        buf.append(chunk)
        while let nl = buf.firstIndex(of: 10) {
            let line = buf.subdata(in: buf.startIndex..<nl)
            buf.removeSubrange(buf.startIndex...nl)
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            for out in codexStep(obj, state: &state) { send(out) }
            if state.stage == 3 { break read }
        }
    }
    if let f = state.failure { return (nil, f) }
    if state.stage == 3 { return (state.snapshot, nil) }
    if state.stage == 2 {
        state.snapshot.note = "Token request timed out"
        return (state.snapshot, nil)
    }
    return (nil, "Codex app-server did not respond")
}

// MARK: - Location (one shot, when-in-use)

final class Locator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onCoordinate: ((Double, Double) -> Void)?

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let c = locations.last?.coordinate { onCoordinate?(c.latitude, c.longitude) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - Battery (read-only, AppleSmartBattery)

struct BatteryInfo {
    var percent: Int
    var state: String
    var cycles: Int?
    var maxPercent: Int?
    var maxMAh: Int?
    var designMAh: Int?
    var tempC: Double?
    var condition: String
}

func readBattery() -> BatteryInfo? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let cfDict = props?.takeRetainedValue(),
          let p = cfDict as NSDictionary as? [String: Any] else { return nil }

    let cur = p["CurrentCapacity"] as? Int ?? 0
    let max = p["MaxCapacity"] as? Int ?? 0
    // Apple silicon reports 0-100 here; Intel reports mAh.
    let percent = max > 0 ? Int((Double(cur) * 100 / Double(max)).rounded()) : cur
    let charging = p["IsCharging"] as? Bool ?? false
    let plugged = p["ExternalConnected"] as? Bool ?? false
    let full = p["FullyCharged"] as? Bool ?? false
    let state = charging ? "Charging" : (plugged ? (full ? "Charged" : "Plugged in") : "On battery")

    let design = p["DesignCapacity"] as? Int
    let rawMax = p["AppleRawMaxCapacity"] as? Int ?? (max > 100 ? max : nil)
    var maxPercent: Int?
    if let r = rawMax, let d = design, d > 0 { maxPercent = Int((Double(r) * 100 / Double(d)).rounded()) }
    // macOS does not expose "Condition" in the registry; this mirrors the 80% service threshold.
    let condition = (maxPercent ?? 100) >= 80 ? "Normal" : "Service Recommended"

    return BatteryInfo(
        percent: percent, state: state, cycles: p["CycleCount"] as? Int,
        maxPercent: maxPercent, maxMAh: rawMax, designMAh: design,
        tempC: (p["Temperature"] as? Int).map { Double($0) / 100 }, condition: condition)
}
