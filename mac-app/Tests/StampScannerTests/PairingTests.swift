import XCTest
@testable import StampScanner

/// The iOS companion app has its own copy of `pairingCode(for:)` (in
/// ios-app/StampScannerIOS/Pairing/PairingStore.swift — `PairingCode.derive`).
/// Both sides MUST compute the same 6-digit code from the same secret
/// or pairing silently fails.
///
/// We can't `@import` the iOS Swift file directly (different target),
/// so this test pins the algorithm: SHA-256 of the secret, take first
/// 3 bytes as a 24-bit int, mod 1,000,000, zero-pad to 6 digits.
final class PairingTests: XCTestCase {
    func testCodeIsSixDigits() {
        for _ in 0..<20 {
            let secret = PairingStore.rotateSecret()
            let code = PairingStore.pairingCode(for: secret)
            XCTAssertEqual(code.count, 6, "code must be 6 digits: \(code)")
            XCTAssertTrue(code.allSatisfy(\.isNumber),
                          "code must be numeric: \(code)")
        }
        // Clean up the keychain entry rotateSecret persists.
        PairingStore.clear()
    }

    func testCodeIsDeterministic() {
        // Same input → same code, always.
        let secret = "YS01a2V5Zm9yLXRlc3Rpbmc="  // arbitrary base64-ish
        let c1 = PairingStore.pairingCode(for: secret)
        let c2 = PairingStore.pairingCode(for: secret)
        XCTAssertEqual(c1, c2)
    }

    func testDifferentSecretsProduceDifferentCodes() {
        // Not a guarantee (24-bit space → collisions every ~1900 secrets)
        // but two unrelated secrets should almost always differ.
        let a = PairingStore.pairingCode(for: "secret-alpha-2026")
        let b = PairingStore.pairingCode(for: "secret-beta-2026")
        XCTAssertNotEqual(a, b)
    }

    func testKnownGoldenValue() {
        // Pin the algorithm so future refactors can't silently change
        // the code derivation (would break every paired iPhone overnight).
        // Computed: SHA-256("hello-world-stamp-scanner"),
        // take first 3 bytes as big-endian uint, mod 1,000,000.
        let code = PairingStore.pairingCode(for: "hello-world-stamp-scanner")
        XCTAssertEqual(code, "639049")
    }
}
