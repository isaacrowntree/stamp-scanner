import SwiftUI
import UIKit

struct CaptureView: View {
    @EnvironmentObject var pairing: PairingStore
    @StateObject private var camera = CameraManager()
    @StateObject private var gate = MotionGate()
    @StateObject private var queue = UploadQueue()
    @StateObject private var connection = ConnectionMonitor()

    @State private var autoCapture = true
    @State private var showUnpairConfirm = false
    @State private var flashOpacity: Double = 0

    var body: some View {
        Group {
            if camera.permissionDenied {
                PermissionDeniedView()
            } else {
                captureScene
            }
        }
        .onAppear {
            // Prevent the phone from auto-locking while scanning — camera
            // session pauses on lock, missing captures.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .alert("Unpair iPhone?", isPresented: $showUnpairConfirm) {
            Button("Unpair", role: .destructive) { pairing.clear() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You'll need the 6-digit code from your Mac to re-pair.")
        }
    }

    private var captureScene: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { triggerCapture() }
                .onAppear {
                    wire()
                    Task { await camera.start() }
                    connection.start(bond: pairing.bond)
                }
                .onChange(of: pairing.bond) { _, bond in
                    queue.bond = bond
                    connection.start(bond: bond)
                }

            // Capture-fired flash (screen briefly whites out)
            Color.white
                .opacity(flashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding()
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { showUnpairConfirm = true } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 8, height: 8)
                    Image(systemName: "desktopcomputer")
                    Text(connectionLabel)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
                .foregroundStyle(.white)
            }
            Spacer()
            if camera.torchSupported {
                Button { camera.toggleTorch() } label: {
                    Image(systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .foregroundStyle(camera.torchOn ? .yellow : .white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
            Toggle("Auto", isOn: $autoCapture)
                .toggleStyle(.button)
                .tint(.blue)
                .controlSize(.small)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
                .foregroundStyle(.white)
        }
    }

    private var connectionColor: Color {
        switch connection.state {
        case .online:  return .green
        case .offline: return .red
        case .unknown: return .gray
        }
    }

    private var connectionLabel: String {
        switch connection.state {
        case .online:  return pairing.bond?.peerName ?? "Paired"
        case .offline: return "Mac offline"
        case .unknown: return "Connecting…"
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            SharpnessHUD(score: gate.blurScore, threshold: gate.blurThreshold)
            lensPicker
            HStack {
                counter
                Spacer()
            }
            .padding(.horizontal, 12)
        }
    }

    private var lensPicker: some View {
        HStack(spacing: 0) {
            ForEach(camera.availableLenses) { lens in
                Button {
                    camera.setLens(lens)
                } label: {
                    Text(lens.label)
                        .font(.system(size: 14, weight: camera.currentLens == lens ? .bold : .regular,
                                      design: .rounded))
                        .foregroundStyle(camera.currentLens == lens ? .yellow : .white)
                        .frame(width: 44, height: 44)
                        .background(
                            camera.currentLens == lens
                                ? Color.white.opacity(0.2)
                                : Color.clear,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private var counter: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(queue.uploadedCount)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(queue.pendingCount > 0 ? "queued: \(queue.pendingCount)" : "uploaded")
                .font(.caption)
                .foregroundStyle(queue.pendingCount > 0 ? .orange : .secondary)
            if let err = queue.lastError, connection.state == .offline {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Capture + feedback

    private func triggerCapture() {
        gate.forceRearm()
        camera.capture()
    }

    private func onCaptureCompleted() {
        // Subtle screen flash so the user knows a capture happened.
        flashOpacity = 0.5
        withAnimation(.easeOut(duration: 0.25)) {
            flashOpacity = 0
        }
        // Haptic matches the native Camera app's shutter tap.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func wire() {
        queue.bond = pairing.bond
        camera.onSample = { [weak gate] buf in
            Task { @MainActor in gate?.ingest(buffer: buf) }
        }
        camera.onCaptured = { [weak queue] data in
            Task { @MainActor in
                queue?.submit(data)
                onCaptureCompleted()
            }
        }
        gate.onEvent = { [weak camera] event in
            guard event == .stable, autoCapture else { return }
            Task { @MainActor in camera?.capture() }
        }
    }
}
