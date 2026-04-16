import Foundation
import Security
import Combine

/// Persistent pairing state on the phone: which Mac are we bonded to and
/// what's the shared bearer secret. Lives in the iOS Keychain so it survives
/// relaunches but stays inaccessible to other apps.
@MainActor
final class PairingStore: ObservableObject {
    private static let service = "com.triptech.StampScannerIOS"
    private static let account = "pairing"

    struct Bond: Codable, Equatable {
        let host: String            // e.g. "Isaac-MacBook-Pro.local" or IP
        let port: Int               // always 47000 for now
        let peerName: String        // human-readable (Bonjour TXT or service name)
        let secret: String          // base64 bearer token
    }

    @Published private(set) var bond: Bond?

    init() { self.bond = Self.load() }

    var isPaired: Bool { bond != nil }

    func save(_ bond: Bond) {
        self.bond = bond
        let data = (try? JSONEncoder().encode(bond)) ?? Data()
        Self.write(data)
    }

    func clear() {
        self.bond = nil
        Self.wipe()
    }

    // MARK: - Keychain helpers

    private static func load() -> Bond? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Bond.self, from: data)
    }

    private static func write(_ data: Data) {
        wipe()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func wipe() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

/// Derives the same 6-digit pairing code the Mac displays, from the same
/// shared secret. Matches PairingStore.pairingCode() on the Mac side.
enum PairingCode {
    static func derive(from secret: String) -> String {
        let data = Data(secret.utf8)
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { ptr in
            CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        let value = (UInt32(digest[0]) << 16) | (UInt32(digest[1]) << 8) | UInt32(digest[2])
        return String(format: "%06d", value % 1_000_000)
    }
}

@_silgen_name("CC_SHA256")
private func CC_SHA256(_ data: UnsafeRawPointer?, _ len: CC_LONG,
                        _ md: UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8>?
// Name mirrors Apple's CommonCrypto typedef.
// swiftlint:disable:next type_name
private typealias CC_LONG = UInt32
