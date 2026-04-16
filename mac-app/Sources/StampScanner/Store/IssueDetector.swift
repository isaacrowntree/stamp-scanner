import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import GRDB

/// Quality / duplicate detection across the whole library. Runs three
/// checks and writes issue tags into `StampRecord.issueTags`:
///   * `duplicate` — Vision feature-print Euclidean distance < threshold
///   * `obscured`  — low variance OR low Laplacian sharpness (suggests
///                   stamp was photographed through a sleeve / album page)
///   * `partial`   — aspect ratio > 2.2:1 or dimension < 60px
///
/// Feature prints are cached per stamp at
/// `<captures>/<id>/featureprint.bin` so a re-run is fast after the first
/// pass (only newly-added stamps need computing).
@MainActor
final class IssueDetector: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var running = false
    @Published private(set) var lastSummary: String = ""
    @Published private(set) var lastLog: String = ""

    struct Thresholds {
        /// Vision feature-print distance <= this means same stamp.
        /// Empirical scale (VNGenerateImageFeaturePrintRequest):
        ///   0.00       identical image
        ///   0.20–0.40  same stamp, different lighting/exposure
        ///   0.80–1.30  two visually-similar but distinct stamps
        ///   1.50+      clearly unrelated
        /// Threshold 0.5 is tight enough to not group different stamps
        /// while forgiving of lighting variation on genuine duplicates.
        var duplicateDistance: Float = 0.5
        /// Pixel-variance floor. A 32×32 greyscale with stdev below this
        /// is washed out. Scale: 0–255 per pixel.
        var obscuredVarianceMax: Double = 200
        /// Laplacian variance floor on 256×256. Below = blurry/covered.
        var obscuredSharpnessMax: Float = 150
        /// Aspect-ratio threshold for partial.
        var partialAspectMax: Double = 2.2
        /// Minimum crop side (px).
        var partialMinSide: Int = 60
    }
    var thresholds = Thresholds()

    private struct Analysed {
        let record: StampRecord
        let fp: VNFeaturePrintObservation?
        let obscured: Bool
        let partial: Bool
    }

    private let ci = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Entrypoint

    func runAll() {
        guard !running else { return }
        running = true
        progress = 0
        lastSummary = ""
        logLine("=== IssueDetector starting ===")
        Task.detached { [weak self] in
            await self?.doRun()
        }
    }

    /// Print to stdout (visible in `./run.sh` terminal) AND stash the last
    /// line on self so UI can surface it. Flushes stdout so the terminal
    /// output is live, not buffered.
    private func logLine(_ msg: String) {
        print("[issues] \(msg)")
        fflush(stdout)
        lastLog = msg
    }

    private func doRun() async {
        do {
            let records: [StampRecord] = try await LibraryDatabase.shared.read { db in
                try StampRecord.fetchAll(db)
            }
            await MainActor.run { self.logLine("loaded \(records.count) records") }

            // Phase 1: analyse each record. Per-stamp try/catch so one
            // corrupt image can't kill the whole run.
            var analysed: [Analysed] = []
            analysed.reserveCapacity(records.count)
            var failures = 0
            for (i, record) in records.enumerated() {
                let url = record.cropURL
                guard FileManager.default.fileExists(atPath: url.path) else {
                    await MainActor.run {
                        self.logLine("  [\(i+1)/\(records.count)] \(record.id): crop missing, skipping")
                    }
                    continue
                }
                let fp: VNFeaturePrintObservation? = autoreleasepool {
                    loadOrComputeFeaturePrint(for: record, imageURL: url)
                }
                if fp == nil { failures += 1 }
                let obscured = autoreleasepool { isObscured(url: url) }
                let partial = isPartial(record: record)
                analysed.append(Analysed(record: record, fp: fp,
                                         obscured: obscured, partial: partial))
                if (i + 1) % 25 == 0 || i + 1 == records.count {
                    await MainActor.run {
                        self.logLine("  analysed \(i+1)/\(records.count)")
                    }
                }
                let p = Double(i + 1) / Double(max(records.count, 1)) * 0.6
                await MainActor.run { self.progress = p }
            }
            if failures > 0 {
                await MainActor.run {
                    self.logLine("phase 1: \(failures) feature-print failures (see above)")
                }
            }

            // Phase 2: duplicate detection — pairwise feature-print distance.
            // For each group of near-matches, pick the best (conf × pixels)
            // as keeper; rest get duplicateOf = keeper.id.
            var duplicateOfMap: [String: String] = [:]
            let withFP = analysed.compactMap { item -> (StampRecord, VNFeaturePrintObservation)? in
                guard let fp = item.fp else { return nil }
                return (item.record, fp)
            }
            await MainActor.run {
                self.logLine("phase 2: duplicate pairs across \(withFP.count) stamps")
            }
            var processed = Set<String>()
            for i in 0..<withFP.count {
                if i % 20 == 0 {
                    let p = 0.6 + 0.4 * Double(i) / Double(max(withFP.count, 1))
                    await MainActor.run { self.progress = p }
                }
                let (a, fpA) = withFP[i]
                if processed.contains(a.id) { continue }
                var cluster: [(StampRecord, Float)] = [(a, 0)]
                for j in (i + 1)..<withFP.count {
                    let (b, fpB) = withFP[j]
                    if processed.contains(b.id) { continue }
                    var d: Float = 0
                    do {
                        try fpA.computeDistance(&d, to: fpB)
                    } catch {
                        continue
                    }
                    if d <= thresholds.duplicateDistance {
                        cluster.append((b, d))
                    }
                }
                if cluster.count > 1 {
                    let keeper = cluster.max { lhs, rhs in
                        quality(lhs.0) < quality(rhs.0)
                    }!.0
                    for (r, dist) in cluster where r.id != keeper.id {
                        duplicateOfMap[r.id] = keeper.id
                        processed.insert(r.id)
                        await MainActor.run {
                            self.logLine("  dup: \(r.id) ~ \(keeper.id) (d=\(String(format: "%.2f", dist)))")
                        }
                    }
                    processed.insert(keeper.id)
                }
            }

            // Phase 3: build the per-record updates up-front (so the db
            // closure captures only immutable data — required under Swift 6
            // sendable-closure rules), then write them in one transaction.
            var dupCount = 0, obsCount = 0, partCount = 0
            var updates: [(record: StampRecord, tags: [String], duplicateOf: String?)] = []
            updates.reserveCapacity(analysed.count)
            for item in analysed {
                var tags: [String] = []
                let dupOf = duplicateOfMap[item.record.id]
                if dupOf != nil {
                    tags.append("duplicate"); dupCount += 1
                }
                if item.obscured { tags.append("obscured"); obsCount += 1 }
                if item.partial { tags.append("partial");  partCount += 1 }
                updates.append((item.record, tags, dupOf))
            }
            let finalUpdates = updates
            try await LibraryDatabase.shared.write { db in
                for u in finalUpdates {
                    var r = u.record
                    r.issueTags = u.tags
                    r.duplicateOf = u.duplicateOf
                    try r.update(db)
                }
            }

            let summary = "\(dupCount) duplicate, \(obsCount) obscured, \(partCount) partial"
            await MainActor.run {
                self.lastSummary = summary
                self.progress = 1.0
                self.running = false
            }
        } catch {
            await MainActor.run {
                self.lastSummary = "Error: \(error.localizedDescription)"
                self.running = false
            }
        }
    }

    // MARK: - Checks

    private func quality(_ r: StampRecord) -> Double {
        r.confidence * Double(r.cropW * r.cropH)
    }

    // `internal` for tests.
    func isPartial(record: StampRecord) -> Bool {
        let w = Double(record.cropW), h = Double(record.cropH)
        let minSide = min(w, h), maxSide = max(w, h)
        if minSide < Double(thresholds.partialMinSide) { return true }
        return (maxSide / max(minSide, 1)) > thresholds.partialAspectMax
    }

    func isObscured(url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        let variance = pixelVariance(cg: cg, side: 32)
        let sharpness = laplacianVariance(cg: cg, side: 256)
        return variance < thresholds.obscuredVarianceMax
            || sharpness < thresholds.obscuredSharpnessMax
    }

    private func pixelVariance(cg: CGImage, side: Int) -> Double {
        let cs = CGColorSpaceCreateDeviceGray()
        var bytes = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(
            data: &bytes, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side,
            space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 255 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum: Double = 0, sum2: Double = 0
        for b in bytes {
            let v = Double(b)
            sum += v; sum2 += v * v
        }
        let n = Double(side * side)
        let mean = sum / n
        let variance = (sum2 / n) - (mean * mean)
        return variance
    }

    private func laplacianVariance(cg: CGImage, side: Int) -> Float {
        let src = CIImage(cgImage: cg)
        let scale = CGFloat(side) / max(src.extent.width, 1)
        let scaled = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let luma = CIFilter.colorMatrix()
        luma.inputImage = scaled
        luma.rVector = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
        luma.gVector = .init(x: 0, y: 0, z: 0, w: 0)
        luma.bVector = .init(x: 0, y: 0, z: 0, w: 0)
        guard let lumaImg = luma.outputImage?.cropped(
            to: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))) else { return 0 }
        let k = CIFilter.convolution3X3()
        k.inputImage = lumaImg
        k.weights = CIVector(values: [-1, -1, -1, -1, 8, -1, -1, -1, -1], count: 9)
        guard let lap = k.outputImage?.cropped(to: lumaImg.extent) else { return 0 }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        ci.render(lap, toBitmap: &bytes, rowBytes: side * 4,
                   bounds: lumaImg.extent, format: .RGBA8, colorSpace: nil)
        var sum: Double = 0, sum2: Double = 0
        let n = side * side
        for i in 0..<n {
            let v = Double(bytes[i * 4])
            sum += v; sum2 += v * v
        }
        let mean = sum / Double(n)
        return Float((sum2 / Double(n)) - (mean * mean))
    }

    // MARK: - Feature prints

    private func loadOrComputeFeaturePrint(for record: StampRecord,
                                            imageURL: URL) -> VNFeaturePrintObservation? {
        let cachePath = imageURL.deletingLastPathComponent()
            .appendingPathComponent("featureprint.bin")
        // Cache invalidation: if the crop mtime > cache mtime, recompute.
        if let cacheAttrs = try? FileManager.default.attributesOfItem(atPath: cachePath.path),
           let cacheDate = cacheAttrs[.modificationDate] as? Date,
           let imgAttrs = try? FileManager.default.attributesOfItem(atPath: imageURL.path),
           let imgDate = imgAttrs[.modificationDate] as? Date,
           cacheDate > imgDate,
           let data = try? Data(contentsOf: cachePath),
           let fp = try? NSKeyedUnarchiver.unarchivedObject(
               ofClass: VNFeaturePrintObservation.self, from: data) {
            return fp
        }
        guard let fp = computeFeaturePrint(at: imageURL) else { return nil }
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: fp, requiringSecureCoding: true) {
            try? data.write(to: cachePath)
        }
        return fp
    }

    func computeFeaturePrint(at url: URL) -> VNFeaturePrintObservation? {
        guard let cg = NSImage(contentsOf: url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let request = VNGenerateImageFeaturePrintRequest()
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }
}
