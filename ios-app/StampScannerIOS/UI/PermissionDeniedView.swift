import SwiftUI
import UIKit

struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill.badge.ellipsis")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            Text("Camera access needed")
                .font(.title2).bold()
            Text("Stamp Scanner can't capture photos without camera permission. Open Settings and enable it for this app.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
