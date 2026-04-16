import Foundation
import Security

/// Bonjour pairing state: the shared secret the iPhone sends in every
/// `Authorization: Bearer …` header, plus a human-readable device name we
/// show in the Mac's UI so the user can confirm which phone is paired.
///
/// Stored in the macOS keychain rather than UserDefaults so it survives
/// cleanly and can't be grepped out of a defaults dump.
enum PairingStore {
    private static let service = "com.triptech.StampScanner"
    private static let account = "pairing.sharedSecret"
    private static let peerNameKey = "pairing.peerName"

    /// Generates + persists a new 32-byte shared secret. Called when a
    /// pairing sheet is opened; overwrites any existing value.
    @discardableResult
    static func rotateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let secret = Data(bytes).base64EncodedString()
        store(secret)
        return secret
    }

    static var currentSecret: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    static var peerName: String? {
        UserDefaults.standard.string(forKey: peerNameKey)
    }

    static func setPeerName(_ name: String) {
        UserDefaults.standard.set(name, forKey: peerNameKey)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: peerNameKey)
    }

    /// Short human-readable code (6 digits) derived from the secret. Shown
    /// on the Mac during pairing and typed on the phone. Derivation is
    /// deterministic so both sides arrive at the same 6 digits without
    /// needing a separate channel.
    static func pairingCode(for secret: String) -> String {
        // SHA-256 the secret, take first 3 bytes as a 24-bit int, mod 1M,
        // zero-pad to 6 digits. Collision-safe for a user-facing code.
        let data = Data(secret.utf8)
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { ptr in
            CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        let value = (UInt32(digest[0]) << 16) | (UInt32(digest[1]) << 8) | UInt32(digest[2])
        return String(format: "%06d", value % 1_000_000)
    }

    private static func store(_ secret: String) {
        clear()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }
}

// CommonCrypto SHA256 without adding a new dependency.
@_silgen_name("CC_SHA256")
private func CC_SHA256(_ data: UnsafeRawPointer?, _ len: CC_LONG,
                        _ md: UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8>?
private typealias CC_LONG = UInt32
