import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Combine

/// Straight port of the Mac's MotionGate — same Core Image algorithm
/// (frame-diff + Laplacian-variance sharpness + luminance) tuned for the
/// iPhone's much sharper sensor. A still, tack-sharp close-up on the iPhone
/// typically scores 800–2500.
@MainActor
final class MotionGate: ObservableObject {
    enum Event { case stable, changed }

    @Published private(set) var isMoving = false
    @Published private(set) var blurScore: Float = 0
    var blurThreshold: Float { blurMin }
    var onEvent: ((Event) -> Void)?

    // iPhone preview frames are ~1920×1080 even though the shutter captures
    // at 48MP. The Laplacian variance on preview frames maxes out around
    // 400–600 with good lighting + macro. 350 gates out motion blur and
    // focus-hunting while letting well-lit macro shots fire.
    private let moveThreshold: Float = 0.03
    private let changedThreshold: Float = 0.10
    private let blurMin: Float = 350
    // Tight luminance band: a phone face-down produces near-black (mean
    // luma ~0.01–0.05) which has *low* Laplacian variance but easily
    // passes a loose floor. 0.15 rejects face-down/pocket/covered lens.
    private let lumaLo: Float = 0.15
    private let lumaHi: Float = 0.90
    private let settleMs: Int = 180
    private let requiredSharpStreak: Int = 2

    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private var prevLuma: CIImage?
    private var lockedLuma: CIImage?
    private var lastMotionAt = Date()
    private var sharpStreak = 0
    private var readyToFire = true

    func ingest(buffer: CVPixelBuffer) {
        let src = CIImage(cvPixelBuffer: buffer)
        let scale: CGFloat = 192.0 / max(src.extent.width, 1)
        let small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let luma = Self.makeLuma(small)
        guard let luma else { return }

        let now = Date()
        defer { prevLuma = luma }

        if let prev = prevLuma {
            let delta = Self.meanAbsDelta(a: luma, b: prev, ctx: ci)
            if delta > moveThreshold {
                lastMotionAt = now
                sharpStreak = 0
                if !isMoving { isMoving = true }
                if let locked = lockedLuma {
                    let changed = Self.meanAbsDelta(a: luma, b: locked, ctx: ci)
                    if changed > changedThreshold {
                        lockedLuma = nil
                        readyToFire = true
                        onEvent?(.changed)
                    }
                }
                return
            } else if isMoving {
                isMoving = false
            }
        }

        if !readyToFire { return }

        let stillForMs = Int(now.timeIntervalSince(lastMotionAt) * 1000)
        guard stillForMs >= settleMs else { return }

        let meanLuma = Self.meanLuminance(luma: luma, ctx: ci)
        guard meanLuma > lumaLo, meanLuma < lumaHi else {
            sharpStreak = 0
            blurScore = 0
            return
        }

        let blur = Self.centreCropLaplacianVariance(src: src, ctx: ci)
        blurScore = blur
        guard blur > blurMin else { sharpStreak = 0; return }

        sharpStreak += 1
        guard sharpStreak >= requiredSharpStreak else { return }

        lockedLuma = luma
        readyToFire = false
        sharpStreak = 0
        onEvent?(.stable)
    }

    func forceRearm() { readyToFire = true; lockedLuma = nil }
    func resetLock() { lockedLuma = nil; readyToFire = true }

    // MARK: - Core Image helpers

    private static func makeLuma(_ img: CIImage) -> CIImage? {
        let f = CIFilter.colorMatrix()
        f.inputImage = img
        f.rVector = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
        f.gVector = .init(x: 0, y: 0, z: 0, w: 0)
        f.bVector = .init(x: 0, y: 0, z: 0, w: 0)
        return f.outputImage?.cropped(to: img.extent)
    }

    private static func meanLuminance(luma: CIImage, ctx: CIContext) -> Float {
        let avg = CIFilter.areaAverage()
        avg.inputImage = luma
        avg.extent = luma.extent
        guard let out = avg.outputImage else { return 0 }
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)
        return Float(px[0]) / 255.0
    }

    private static func meanAbsDelta(a: CIImage, b: CIImage, ctx: CIContext) -> Float {
        let diff = CIFilter.differenceBlendMode()
        diff.inputImage = a
        diff.backgroundImage = b
        guard let d = diff.outputImage?.cropped(to: a.extent) else { return 0 }
        let avg = CIFilter.areaAverage()
        avg.inputImage = d
        avg.extent = d.extent
        guard let out = avg.outputImage else { return 0 }
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)
        return Float(px[0]) / 255.0
    }

    private static func centreCropLaplacianVariance(src: CIImage, ctx: CIContext) -> Float {
        let side: CGFloat = 512
        let cx = src.extent.midX
        let cy = src.extent.midY
        let crop = src.cropped(to: CGRect(x: cx - side/2, y: cy - side/2,
                                           width: side, height: side))
        let shift = CGAffineTransform(translationX: -(cx - side/2), y: -(cy - side/2))
        let centered = crop.transformed(by: shift)
        guard let luma = makeLuma(centered)?.cropped(to: CGRect(x: 0, y: 0, width: side, height: side)) else { return 0 }
        let k = CIFilter.convolution3X3()
        k.inputImage = luma
        k.weights = CIVector(values: [-1, -1, -1, -1, 8, -1, -1, -1, -1], count: 9)
        k.bias = 0
        guard let lap = k.outputImage?.cropped(to: luma.extent) else { return 0 }
        let w = Int(side), h = Int(side)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        ctx.render(lap, toBitmap: &bytes, rowBytes: w * 4,
                   bounds: luma.extent, format: .RGBA8, colorSpace: nil)
        var sum: Double = 0, sum2: Double = 0
        let n = w * h
        for i in 0..<n {
            let v = Double(bytes[i * 4])
            sum += v
            sum2 += v * v
        }
        let mean = sum / Double(n)
        return Float((sum2 / Double(n)) - (mean * mean))
    }
}
