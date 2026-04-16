import SwiftUI

struct CaptureView: View {
    @EnvironmentObject var pairing: PairingStore
    @StateObject private var camera = CameraManager()
    @StateObject private var gate = MotionGate()
    @StateObject private var queue = UploadQueue()

    @State private var autoCapture = true
    @State private var showUnpairConfirm = false

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    gate.forceRearm()
                    camera.capture()
                }
                .onAppear { wire(); Task { await camera.start() } }
                .onChange(of: pairing.bond) { _, bond in queue.bond = bond }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding()
        }
        .alert("Unpair iPhone?", isPresented: $showUnpairConfirm) {
            Button("Unpair", role: .destructive) { pairing.clear() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You'll need the 6-digit code from your Mac to re-pair.")
        }
    }

    private var topBar: some View {
        HStack {
            Button { showUnpairConfirm = true } label: {
                Label(pairing.bond?.peerName ?? "Paired",
                      systemImage: "desktopcomputer")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.white)
            }
            Spacer()
            Toggle("Auto", isOn: $autoCapture)
                .toggleStyle(.button)
                .tint(.blue)
                .controlSize(.small)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
                .foregroundStyle(.white)
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
            if let err = queue.lastError {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func wire() {
        queue.bond = pairing.bond
        camera.onSample = { [weak gate] buf in
            Task { @MainActor in gate?.ingest(buffer: buf) }
        }
        camera.onCaptured = { [weak queue] data in
            Task { @MainActor in queue?.submit(data) }
        }
        gate.onEvent = { [weak camera] event in
            guard event == .stable, autoCapture else { return }
            Task { @MainActor in camera?.capture() }
        }
    }
}
