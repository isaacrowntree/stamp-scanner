import SwiftUI

/// Pair-an-iPhone sheet. Flow:
///   1. Sheet opens → generate a fresh shared secret + derive 6-digit code.
///   2. PhoneIngestServer rebinds to LAN + advertises Bonjour service
///      "_stampscanner._tcp" under this Mac's name.
///   3. User types the code on the iPhone; the phone POSTs /health to
///      confirm the Mac accepted it (first submit counts as "paired").
///   4. As soon as a POST /submit lands, we flip to "paired" UI.
///
/// On sheet dismiss, we keep the LAN listener up so the phone can keep
/// submitting; Bonjour advertisement is stopped (phone cached the host).
struct PairingSheet: View {
    @EnvironmentObject var server: PhoneIngestServer
    @Binding var visible: Bool
    @State private var code: String = ""
    @State private var startJobCount: Int = 0
    @State private var paired: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair iPhone Scanner")
                .font(.title2).bold()
            Text("Open the Stamp Scanner app on your iPhone, pick this Mac, and enter the code below.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Text(formatted(code: code))
                .font(.system(size: 42, weight: .semibold, design: .monospaced))
                .padding(.vertical, 8)

            if paired {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Paired! Scans from your iPhone will appear in the library automatically.")
                        .font(.callout)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for iPhone…").foregroundStyle(.secondary)
                }
            }

            Spacer()
            HStack {
                Button("Unpair") {
                    PairingStore.clear()
                    server.start(mode: .off)
                    visible = false
                }
                .disabled(PairingStore.currentSecret == nil)
                Spacer()
                Button(paired ? "Done" : "Cancel") { visible = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .onAppear {
            let secret = PairingStore.rotateSecret()
            code = PairingStore.pairingCode(for: secret)
            startJobCount = server.jobCount
            server.start(mode: .lan, advertiseAs: Host.current().localizedName ?? "Mac")
        }
        .onChange(of: server.jobCount) { _, new in
            if new > startJobCount { paired = true }
        }
    }

    private func formatted(code: String) -> String {
        guard code.count == 6 else { return code }
        let a = code.prefix(3), b = code.suffix(3)
        return "\(a) \(b)"
    }
}
