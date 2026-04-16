import AVFoundation
import UIKit
import Combine

/// Lens options matching the native Camera app.
enum Lens: String, CaseIterable, Identifiable {
    case ultraWide = "0.5"
    case wide      = "1"
    case tele      = "3"

    var id: String { rawValue }
    var label: String { rawValue + "×" }

    /// The video zoom factor on a builtInTripleCamera virtual device
    /// that selects the physical constituent lens. These are the standard
    /// switchover points for iPhone 15 Pro.
    var zoomFactor: CGFloat {
        switch self {
        case .ultraWide: return 1.0   // 0.5× on triple = videoZoomFactor 1.0
        case .wide:      return 2.0   // 1× = factor 2.0 on the triple
        case .tele:      return 6.0   // 3× = factor 6.0 on the triple
        }
    }
}

final class CameraManager: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var isReady = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var currentLens: Lens = .wide
    @Published private(set) var availableLenses: [Lens] = []

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let sampleQueue = DispatchQueue(label: "camera.samples", qos: .userInitiated)
    private var currentDevice: AVCaptureDevice?

    var onSample: ((CVPixelBuffer) -> Void)?
    var onCaptured: ((Data) -> Void)?

    @MainActor
    func start() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            permissionDenied = true
            return
        }
        configure()
        let s = session
        Task.detached { s.startRunning() }
        isReady = true
    }

    @MainActor
    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    @MainActor
    func capture() {
        let settings = AVCapturePhotoSettings(format: [
            AVVideoCodecKey: AVVideoCodecType.hevc
        ])
        settings.photoQualityPrioritization = .balanced
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    @MainActor
    func setLens(_ lens: Lens) {
        guard let device = currentDevice else { return }
        currentLens = lens
        try? device.lockForConfiguration()
        device.ramp(toVideoZoomFactor: lens.zoomFactor, withRate: 16.0)
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = (lens == .ultraWide) ? .near : .none
        }
        device.unlockForConfiguration()
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        let candidates: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera,
        ]
        var picked: AVCaptureDevice?
        var pickedType: AVCaptureDevice.DeviceType?
        for t in candidates {
            if let d = AVCaptureDevice.default(t, for: .video, position: .back) {
                picked = d; pickedType = t; break
            }
        }
        guard let device = picked,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        currentDevice = device

        // Determine which lenses are available for the UI buttons.
        switch pickedType {
        case .builtInTripleCamera:
            availableLenses = [.ultraWide, .wide, .tele]
        case .builtInDualWideCamera:
            availableLenses = [.ultraWide, .wide]
        default:
            availableLenses = [.wide]
        }
        currentLens = .ultraWide

        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        device.videoZoomFactor = Lens.ultraWide.zoomFactor
        device.unlockForConfiguration()

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                        didOutput sampleBuffer: CMSampleBuffer,
                        from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onSample?(buffer)
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                      didFinishProcessingPhoto photo: AVCapturePhoto,
                      error: Error?) {
        if let error {
            print("photo capture failed: \(error)")
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        onCaptured?(data)
    }
}
