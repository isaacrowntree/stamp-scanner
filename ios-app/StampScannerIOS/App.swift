import SwiftUI

@main
struct StampScannerIOSApp: App {
    @StateObject private var pairing = PairingStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(pairing)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}

struct RootView: View {
    @EnvironmentObject var pairing: PairingStore
    var body: some View {
        if pairing.isPaired {
            CaptureView()
        } else {
            PairingView()
        }
    }
}
