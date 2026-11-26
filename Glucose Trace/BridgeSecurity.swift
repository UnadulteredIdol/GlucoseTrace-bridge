import Foundation
import Security

// ---------------------------------------------------------------------------
// Sealed BLE packet, protocol v5 (16 bytes) -- must match ext4.js on the
// watch and PROTOCOL.md.
//
//   Byte 0-3   : nonce uint32 LE = unix seconds, strictly increasing
//   Byte 4-11  : 8-byte message (BridgeMessage), XOR-encrypted with E(nonce, 0)
//   Byte 12-15 : tag = first word of E(E(nonce, 0xFFFFFFFF) ^ message)
//
// The reading is exactly one XTEA block, so both the keystream and the MAC
// take a single block.
//
// E is XTEA (128-bit key, 64-bit block, 32 cycles), chosen because the
// watch's ES5 JavaScript has no crypto library and XTEA fits in a few lines.
// This is a CTR + CBC-MAC construction in the style of CCM: the keystream
// and MAC blocks use different second words, so they never collide. The
// nonce doubles as a timestamp; the watch rejects packets more than 10 min
// from its own clock or not newer than the last one it accepted (replay).
// ---------------------------------------------------------------------------
enum PacketSealer {
    static func xtea(_ block: (UInt32, UInt32), key k: [UInt32]) -> (UInt32, UInt32) {
        var (v0, v1) = block
        var sum: UInt32 = 0
        let delta: UInt32 = 0x9E3779B9
        for _ in 0..<32 {
            v0 &+= (((v1 << 4) ^ (v1 >> 5)) &+ v1) ^ (sum &+ k[Int(sum & 3)])
            sum &+= delta
            v1 &+= (((v0 << 4) ^ (v0 >> 5)) &+ v0) ^ (sum &+ k[Int((sum >> 11) & 3)])
        }
        return (v0, v1)
    }

    static func keyWords(_ key: Data) -> [UInt32] {
        let b = [UInt8](key)
        return (0..<4).map { i in le32(b, i * 4) }
    }

    static func seal(_ reading: [UInt8], nonce: UInt32, key: Data) -> Data {
        precondition(reading.count == 8 && key.count == 16)
        let k = keyWords(key)
        let ks = xtea((nonce, 0), key: k)
        let stream = bytes(ks.0) + bytes(ks.1)
        let cipher = (0..<8).map { reading[$0] ^ stream[$0] }

        let x = xtea((nonce, 0xFFFFFFFF), key: k)
        let tag = xtea((x.0 ^ le32(reading, 0), x.1 ^ le32(reading, 4)), key: k).0
        return Data(bytes(nonce) + cipher + bytes(tag))
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    private static func bytes(_ w: UInt32) -> [UInt8] {
        [UInt8(w & 0xFF), UInt8(w >> 8 & 0xFF), UInt8(w >> 16 & 0xFF), UInt8(w >> 24)]
    }
}

// ---------------------------------------------------------------------------
// The 8-byte messages of protocol v5 (PROTOCOL.md section 4.1): two
// little-endian words, p0 = bytes 0-3 and p1 = bytes 4-7, with the message
// type in p0 bits 0-2. No field crosses from p0 into p1, and reserved bits
// are sent as 0. The watch ignores types it doesn't know.
// ---------------------------------------------------------------------------
enum BridgeMessage {
    /// Type 2 codes: why the watch gets no (new) data. Shown on the watch's
    /// IOB / COB line; loginFailed also buzzes once.
    enum Status: Int { case ok = 0, noInternet, sourceDown, loginFailed, noNewData, noSensor, bridgeOff }
    enum Source: Int { case nightscout = 0, libreLinkUp, dexcomShare, other }

    /// Type 0, the live reading. glucose 0 = no reading (send trend 0, rate 0
    /// and age 255 with it). iob in units, cob in grams, loop in minutes since
    /// the pump confirmed a change; nil = unknown. Capped as the watch shows
    /// them: IOB +-51 U, COB 126 g, loop 126 min.
    static func live(glucose: Int, trend: Int, unitMgdl: Bool, aidAlert: Bool, rate: Int, age: Int,
                     iob: Double?, cob: Double?, loop: Int?) -> [UInt8] {
        let rate = UInt32(UInt8(bitPattern: Int8(max(-128, min(rate, 127)))))
        let p0 = UInt32(max(0, min(glucose, 1023))) << 3 | UInt32(trend & 7) << 13
            | (unitMgdl ? 1 << 16 : 0) | (aidAlert ? 1 << 17 : 0) | rate << 18
        let i = iob.map { UInt32(max(0, min(Int(($0 * 10).rounded()) + 512, 1022))) } ?? 1023
        let c = cob.map { UInt32(max(0, min(Int($0.rounded()), 126))) } ?? 127
        let l = loop.map { UInt32(max(0, min($0, 126))) } ?? 127
        let p1 = UInt32(max(0, min(age, 255))) | c << 8 | l << 15 | i << 22
        return bytes(p0) + bytes(p1)
    }

    /// Type 1, history for the watch's 3-hour graph: the readings (mg/dL,
    /// 0 = none) of five consecutive 5-minute blocks, the first in block
    /// floor(nonce / 300) - offset, each next one a block earlier.
    static func history(offset: Int, readings: [Int]) -> [UInt8] {
        precondition(readings.count == 5)
        let v = readings.map { UInt32(max(0, min($0, 1023))) }
        let p0 = 1 | UInt32(max(0, min(offset, 255))) << 3 | v[0] << 11 | v[1] << 21
        return bytes(p0) + bytes(v[2] | v[3] << 10 | v[4] << 20)
    }

    /// The next history packet from a queue of (mg/dL, block = unix time / 300),
    /// newest first, one reading per block: takes up to five consecutive
    /// blocks off the queue. nil when it is empty.
    static func history(from queue: inout [(sgv: Int, block: Int)], nonce: UInt32) -> [UInt8]? {
        guard let top = queue.first?.block else { return nil }
        var readings = [0, 0, 0, 0, 0]
        while let q = queue.first, q.block > top - 5 {
            if q.block <= top { readings[top - q.block] = q.sgv }
            queue.removeFirst()
        }
        return history(offset: Int(nonce / 300) - top, readings: readings)
    }

    /// Type 2, the bridge's status. Sent when it changes, and after the live
    /// reading on every new subscription (also when ok).
    static func status(_ code: Status, source: Source) -> [UInt8] {
        bytes(2 | UInt32(code.rawValue) << 3 | UInt32(source.rawValue) << 7) + [0, 0, 0, 0]
    }

    private static func bytes(_ w: UInt32) -> [UInt8] {
        [UInt8(w & 0xFF), UInt8(w >> 8 & 0xFF), UInt8(w >> 16 & 0xFF), UInt8(w >> 24)]
    }
}

// ---------------------------------------------------------------------------
// Keychain storage for the Nightscout token and the bridge key. Items are
// readable after first unlock (the bridge runs with the screen locked) and
// never leave this device (no iCloud Keychain sync; a backup restores them
// only to this same device).
// ---------------------------------------------------------------------------
enum Keychain {
    private static let service = "NZ.GlucoseTrace"

    static func data(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        var out: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func set(_ value: Data?, _ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        guard let value, !value.isEmpty else { SecItemDelete(query as CFDictionary); return }
        // Update in place, add only when missing: delete-then-add lost the
        // value if the add failed.
        let attrs: [String: Any] = [kSecValueData as String: value,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var item = query
            item.merge(attrs) { $1 }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func string(_ account: String) -> String {
        data(account).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    static func setString(_ value: String, _ account: String) {
        set(value.data(using: .utf8), account)
    }

    // 16 random bytes, created on first use. Only generated when no key
    // exists -- a Keychain that is merely unavailable (e.g. before first
    // unlock) must not silently replace the key the watch already has.
    // nil while it can't be read: never shown, copied or used to seal (an
    // all-zero stand-in could be pasted into the watch and is no secret).
    static func bridgeKey() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "bridgeKey",
                                    kSecReturnData as String: true]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess, let key = out as? Data, key.count == 16 { return key }
        if status == errSecItemNotFound { return newBridgeKey() }
        return nil
    }
    @discardableResult
    static func newBridgeKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed")
        }
        let key = Data(bytes)
        set(key, "bridgeKey")
        return key
    }
}

extension Data {
    // "1A2B 3C4D ..." -- groups of four for typing into the Suunto app.
    var groupedHex: String {
        let hex = map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[s..<hex.index(s, offsetBy: 4)])
        }.joined(separator: " ")
    }
}
