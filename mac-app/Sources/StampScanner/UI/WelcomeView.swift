import SwiftUI

/// Shown until a bearer secret is stored in the Keychain. Displays the
/// 6-digit pairing code inline so the user never has to open a sheet —
/// just launch the iOS app, pick this Mac, type the code.
struct WelcomeView: View {
    @EnvironmentObject var server: PhoneIngestServer
    @State private var code: String = ""
    @State private var paired = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 80, weight: .light))
                .foregroundStyle(.tint)
            Text("Pair your iPhone")
                .font(.system(size: 32, weight: .semibold))
            Text("Open Stamp Scanner on your iPhone, tap this Mac when it appears, then type the code below.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            Text(formatted(code))
                .font(.system(size: 56, weight: .semibold, design: .monospaced))
                .tracking(4)
                .padding(.horizontal, 28).padding(.vertical, 14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for your iPhone…").foregroundStyle(.secondary)
            }
            Spacer()
            Text("Pairing uses your local Wi-Fi only. No cloud.")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let secret = PairingStore.rotateSecret()
            code = PairingStore.pairingCode(for: secret)
        }
        .onChange(of: server.jobCount) { _, _ in
            // First submission proves pairing worked — the RootView will
            // flip to LibraryWindow on its next check against keychain.
            paired = (PairingStore.currentSecret != nil)
        }
    }

    private func formatted(_ c: String) -> String {
        guard c.count == 6 else { return c }
        return "\(c.prefix(3)) \(c.suffix(3))"
    }
}
