import Foundation
import IOKit

// Minimal AppleSMC client. The key names, data sizes and byte values below come from the open-source
// projects listed in NOTICE and the README (Battery-Toolkit BSD-3, OpenDente GPL-3, battery MIT,
// batt GPL-2 for key names only). Struct layout and call selectors follow the same projects.

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpu: UInt32 = 0
    var gpu: UInt32 = 0
    var mem: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var attributes: UInt8 = 0
    var pad0: UInt8 = 0
    var pad1: UInt8 = 0
    var pad2: UInt8 = 0
}

/// 80 bytes, matches the kernel struct.
private struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimit = SMCPLimit()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for b in s.utf8.prefix(4) { v = (v << 8) | UInt32(b) }
    return v
}

final class SMCClient {
    private var conn: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func call(_ input: SMCParam) -> SMCParam? {
        var inp = input
        var out = SMCParam()
        var outSize = MemoryLayout<SMCParam>.stride
        let r = IOConnectCallStructMethod(conn, 2, &inp, MemoryLayout<SMCParam>.stride, &out, &outSize)
        return (r == KERN_SUCCESS && out.result == 0) ? out : nil
    }

    /// Data size of a key, or nil if the key does not exist.
    func size(_ key: String) -> Int? {
        var p = SMCParam()
        p.key = fourCC(key)
        p.data8 = 9
        guard let o = call(p), o.keyInfo.dataSize > 0 else { return nil }
        return Int(o.keyInfo.dataSize)
    }

    func read(_ key: String) -> [UInt8]? {
        guard let n = size(key), n <= 32 else { return nil }
        var p = SMCParam()
        p.key = fourCC(key)
        p.keyInfo.dataSize = UInt32(n)
        p.data8 = 5
        guard var o = call(p) else { return nil }
        return withUnsafeBytes(of: &o.bytes) { Array($0.prefix(n)) }
    }

    /// Never writes a key that does not exist or whose size differs from `bytes`; verifies by reading back.
    func write(_ key: String, _ bytes: [UInt8], verify: Bool = true) -> Bool {
        guard let n = size(key), n == bytes.count else { return false }
        var p = SMCParam()
        p.key = fourCC(key)
        p.keyInfo.dataSize = UInt32(n)
        p.data8 = 6
        withUnsafeMutableBytes(of: &p.bytes) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        guard call(p) != nil else { return false }
        return !verify || read(key) == bytes
    }
}

/// One SMC key with its expected size and the bytes meaning "normal" (on) and "inhibited/disabled" (off).
struct SMCControl {
    let key: String
    let size: Int
    let on: [UInt8]
    let off: [UInt8]
}

/// Charging inhibit. First group whose keys all exist wins.
/// CHTE (newer firmware): Battery-Toolkit, OpenDente, batt. CH0B+CH0C (older): OpenDente, battery.sh, batt.
let chargeGroups: [[SMCControl]] = [
    [SMCControl(key: "CHTE", size: 4, on: [0, 0, 0, 0], off: [1, 0, 0, 0])],
    [SMCControl(key: "CH0B", size: 1, on: [0], off: [2]), SMCControl(key: "CH0C", size: 1, on: [0], off: [2])],
]

/// Adapter disable (run on battery while plugged in).
/// CHIE off=0x08: Battery-Toolkit, OpenDente. CH0I off=0x01: OpenDente, battery.sh. CH0J off=0x20: Battery-Toolkit.
let adapterGroups: [[SMCControl]] = [
    [SMCControl(key: "CHIE", size: 1, on: [0], off: [8])],
    [SMCControl(key: "CH0I", size: 1, on: [0], off: [1])],
    [SMCControl(key: "CH0J", size: 1, on: [0], off: [0x20])],
]

let ledKey = "ACLC"
let acPowerKey = "AC-W"   // int8 > 0 while an adapter is connected, even if the adapter is disabled (key name from batt)
