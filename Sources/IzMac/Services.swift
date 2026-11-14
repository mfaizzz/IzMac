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
