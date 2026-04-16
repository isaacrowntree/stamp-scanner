import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import Vision
@testable import StampScanner

/// Tests for IssueDetector's three independent checks. Each check is a
/// pure function of an image or a record, so we exercise them directly
/// without hitting the shared library DB.
///
/// Uses bundled fixtures: these are known-good stamp scans (most are
/// multi-stamp scenes but the tight single-stamp ones work as "clear
/// reference" images).
@MainActor
final class IssueDetectorTests: XCTestCase {
    var detector: IssueDetector!
    var scratch: URL!

    override func setUp() {
        detector = IssueDetector()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("issuedetector-\(UUID().uuidString)",
                                     isDirectory: true)
        try? FileManager.default.createDirectory(
            at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Partial detection

    func testPartialByAspectRatio() {
        // Real issue stamps cap around 2:1; 4:1 is clearly a fragment.
        let narrow = makeRecord(cropW: 100, cropH: 400)
        XCTAssertTrue(detector.isPartial(record: narrow),
                      "aspect 4:1 should be flagged as partial")

        let landscape = makeRecord(cropW: 200, cropH: 120)
        XCTAssertFalse(detector.isPartial(record: landscape),
                       "1.67:1 is a normal landscape stamp, not partial")

        let square = makeRecord(cropW: 300, cropH: 300)
        XCTAssertFalse(detector.isPartial(record: square))
    }

    func testPartialByMinSide() {
        // SAM sometimes returns tiny mask artefacts; anything under 60px
        // is not a real stamp.
        let tiny = makeRecord(cropW: 40, cropH: 120)
        XCTAssertTrue(detector.isPartial(record: tiny),
                      "sub-60px side should be partial")
    }

    // MARK: - Obscured detection

    func testObscuredFlagsLowContrastImage() throws {
        // A nearly-uniform grey rectangle should be obscured (pixel
        // variance is near zero — classic "stamp through a sleeve" look).
        let url = scratch.appendingPathComponent("flat.png")
        try writeSolidColor(to: url, rgb: (180, 180, 180), size: 300)
        XCTAssertTrue(detector.isObscured(url: url),
                      "flat grey image should trip variance floor")
    }

    // MARK: - Feature-print distance

    func testFeaturePrintIdenticalImageIsZeroDistance() throws {
        let fixture = try requireFixture("single_au_kgv", ext: "jpeg")
        let a = detector.computeFeaturePrint(at: fixture)
        let b = detector.computeFeaturePrint(at: fixture)
        let aFP = try XCTUnwrap(a, "feature print failed for A")
        let bFP = try XCTUnwrap(b, "feature print failed for B")
        var distance: Float = -1
        try aFP.computeDistance(&distance, to: bFP)
        XCTAssertEqual(distance, 0, accuracy: 0.001,
                       "identical image should distance 0 from itself")
    }

    func testFeaturePrintDifferentImagesAreFurtherThanThreshold() throws {
        // Two visually-distinct stamps (AU KGV portrait vs Russia eagle)
        // should score well above our tuned dup-threshold (0.5).
        let au = try requireFixture("single_au_kgv", ext: "jpeg")
        let russia = try requireFixture("single_russia_1918", ext: "jpg")
        let auFP = try XCTUnwrap(detector.computeFeaturePrint(at: au))
        let ruFP = try XCTUnwrap(detector.computeFeaturePrint(at: russia))
        var distance: Float = -1
        try auFP.computeDistance(&distance, to: ruFP)
        XCTAssertGreaterThan(distance, detector.thresholds.duplicateDistance,
            "two completely different stamps should exceed dup threshold (got \(distance))")
    }

    // MARK: - Helpers

    private func makeRecord(cropW: Int, cropH: Int) -> StampRecord {
        StampRecord(
            id: "t-\(cropW)x\(cropH)",
            capturedAt: Date(), cropPath: "x/c.png",
            sourceFramePath: nil, confidence: 0.9,
            cropW: cropW, cropH: cropH, quadFlat: []
        )
    }

    private func requireFixture(_ name: String, ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name,
                                           withExtension: ext,
                                           subdirectory: "Fixtures") else {
            XCTFail("missing fixture: \(name).\(ext)")
            throw NSError(domain: "test", code: -1)
        }
        return url
    }

    /// Apply a Gaussian blur via Core Image and write the result as PNG.
    private func blur(_ source: URL, sigma: Double, into dest: URL) throws -> URL {
        guard let img = NSImage(contentsOf: source),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "test", code: -2)
        }
        let ci = CIImage(cgImage: cg)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = ci
        filter.radius = Float(sigma)
        guard let out = filter.outputImage?.cropped(to: ci.extent) else {
            throw NSError(domain: "test", code: -3)
        }
        let ctx = CIContext()
        guard let cgOut = ctx.createCGImage(out, from: ci.extent) else {
            throw NSError(domain: "test", code: -4)
        }
        let rep = NSBitmapImageRep(cgImage: cgOut)
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: dest)
        return dest
    }

    private func writeSolidColor(to url: URL, rgb: (UInt8, UInt8, UInt8), size: Int) throws {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for p in stride(from: 0, to: bytes.count, by: 4) {
            bytes[p + 0] = rgb.0
            bytes[p + 1] = rgb.1
            bytes[p + 2] = rgb.2
            bytes[p + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bmp = CGContext(
            data: &bytes, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cg = bmp.makeImage()!
        let rep = NSBitmapImageRep(cgImage: cg)
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: url)
    }
}
