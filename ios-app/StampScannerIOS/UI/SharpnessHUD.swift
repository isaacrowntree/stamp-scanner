import SwiftUI

struct SharpnessHUD: View {
    let score: Float
    let threshold: Float

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(label).font(.caption).monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(background, in: Capsule())
    }
    private var icon: String {
        if score >= threshold { return "checkmark.seal.fill" }
        if score >= threshold * 0.5 { return "camera.viewfinder" }
        return "camera.metering.unknown"
    }
    private var label: String {
        if score < 5 { return "—" }
        if score >= threshold { return "sharp (\(Int(score)))" }
        return "blurry (\(Int(score))/\(Int(threshold)))"
    }
    private var background: AnyShapeStyle {
        if score >= threshold { return AnyShapeStyle(Color.green.opacity(0.8)) }
        if score >= threshold * 0.5 { return AnyShapeStyle(Color.orange.opacity(0.75)) }
        return AnyShapeStyle(Color.black.opacity(0.55))
    }
}
