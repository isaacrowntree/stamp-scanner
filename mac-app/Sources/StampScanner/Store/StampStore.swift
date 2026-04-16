import Foundation
import AppKit
import GRDB
import GRDBQuery

/// Swift-side store operations. Ingest (save new stamps) is handled
/// entirely by the Python worker which writes directly into library.sqlite.
/// Swift only does delete + update for UI interactions.
@MainActor
enum StampStore {
    static func delete(_ record: StampRecord) throws {
        let dir = Paths.capturesDir.appendingPathComponent(record.id)
        try? FileManager.default.removeItem(at: dir)

        try LibraryDatabase.shared.write { db in
            try record.delete(db)
            if let sourceRel = record.sourceFramePath {
                let still = try StampRecord
                    .filter(StampRecord.Columns.sourceFramePath == sourceRel)
                    .fetchCount(db)
                if still == 0 {
                    let url = Paths.capturesDir.appendingPathComponent(sourceRel)
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    static func update(_ record: StampRecord) throws {
        try LibraryDatabase.shared.write { db in
            try record.update(db)
        }
    }

    /// Rotate the crop PNG on disk only. Intentionally does NOT write to
    /// the DB: if we did, the grid's `@Query` would re-fetch and re-render
    /// the entire LazyVGrid, breaking scroll position and the visual "just
    /// this cell changed" feel. The AsyncImage cache buster uses file mtime
    /// so the re-read happens automatically via URL differentiation.
    /// Posts NotificationCenter so the affected cell can refresh locally.
    static func rotate(_ record: StampRecord, byDegrees degrees: Int) throws {
        let url = record.cropURL
        guard let image = NSImage(contentsOf: url) else { return }
        let rotated = image.rotated(byDegrees: degrees)
        if let data = rotated.pngData() {
            try data.write(to: url, options: .atomic)
        }
        NotificationCenter.default.post(
            name: .stampCropRotated, object: record.id)
    }
}

extension Notification.Name {
    /// Posted with `object = record.id (String)` when a crop PNG is
    /// rewritten by the rotate button. Cells observe and bump their
    /// AsyncImage cache-buster key to re-read the file.
    static let stampCropRotated = Notification.Name("stampCropRotated")
}

private extension NSImage {
    /// Rotate the image; positive = clockwise (matches the user's mental
    /// model of tapping a rotate-right button).
    func rotated(byDegrees degrees: Int) -> NSImage {
        let radians = -CGFloat(degrees) * .pi / 180.0
        let oldSize = self.size
        let newSize: NSSize
        if abs(degrees) % 180 == 90 {
            newSize = NSSize(width: oldSize.height, height: oldSize.width)
        } else {
            newSize = oldSize
        }
        let rotated = NSImage(size: newSize)
        rotated.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: newSize.width / 2, yBy: newSize.height / 2)
        transform.rotate(byRadians: radians)
        transform.translateX(by: -oldSize.width / 2, yBy: -oldSize.height / 2)
        transform.concat()
        draw(at: .zero, from: NSRect(origin: .zero, size: oldSize),
             operation: .copy, fraction: 1)
        rotated.unlockFocus()
        return rotated
    }

    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - GRDBQuery requests

struct StampsRequest: ValueObservationQueryable {
    static var defaultValue: [StampRecord] { [] }
    var filter: LibraryFilter = .init()
    /// Cache buster — bumped by `DatabaseWatcher` when the SQLite file is
    /// modified by an external process (Python worker). The value is unused
    /// inside `fetch`; its only job is to make the request compare unequal
    /// so GRDBQuery re-subscribes and re-runs the fetch.
    var externalTick: Int = 0

    func fetch(_ db: Database) throws -> [StampRecord] {
        var request = StampRecord.all()
        switch filter.folder {
        case .all: break
        case .recent:
            let cutoff = Date().addingTimeInterval(-86_400)
            request = request.filter(StampRecord.Columns.capturedAt > cutoff)
        case .unidentified:
            request = request.filter(
                StampRecord.Columns.country == nil
                && StampRecord.Columns.year == nil)
        case .partials:
            // Tag-based now — IssueDetector marks these explicitly.
            // Fall back to aspect ratio so the folder isn't empty before
            // the user runs the detector.
            request = request.filter(
                sql: "issueTags LIKE '%\"partial\"%'"
                     + " OR (MAX(cropW,cropH) * 1.0 / MIN(cropW,cropH)) > 2.2"
                     + " OR cropW < 60 OR cropH < 60"
            )
        case .obscured:
            request = request.filter(sql: "issueTags LIKE '%\"obscured\"%'")
        case .flagged:
            request = request.filter(StampRecord.Columns.flagged == true)
        case .duplicates:
            request = request.filter(sql: "issueTags LIKE '%\"duplicate\"%'")
        }
        if !filter.search.isEmpty {
            let q = "%\(filter.search.lowercased())%"
            request = request.filter(
                StampRecord.Columns.country.lowercased.like(q)
                || StampRecord.Columns.denomination.lowercased.like(q)
                || StampRecord.Columns.notes.lowercased.like(q)
            )
        }
        switch filter.sort {
        case .newestFirst:
            request = request.order(StampRecord.Columns.capturedAt.desc)
        case .oldestFirst:
            request = request.order(StampRecord.Columns.capturedAt.asc)
        case .highestConfidence:
            request = request.order(StampRecord.Columns.confidence.desc)
        case .lowestConfidence:
            request = request.order(StampRecord.Columns.confidence.asc)
        }
        return try request.fetchAll(db)
    }
}

struct StampCountsRequest: ValueObservationQueryable {
    struct Counts: Equatable {
        var all: Int = 0
        var recent: Int = 0
        var unidentified: Int = 0
        var partials: Int = 0
        var obscured: Int = 0
        var duplicates: Int = 0
        var flagged: Int = 0
    }
    static var defaultValue: Counts { .init() }
    var externalTick: Int = 0

    func fetch(_ db: Database) throws -> Counts {
        let cutoff = Date().addingTimeInterval(-86_400)
        return try Counts(
            all: StampRecord.fetchCount(db),
            recent: StampRecord
                .filter(StampRecord.Columns.capturedAt > cutoff)
                .fetchCount(db),
            unidentified: StampRecord
                .filter(StampRecord.Columns.country == nil
                        && StampRecord.Columns.year == nil)
                .fetchCount(db),
            partials: StampRecord
                .filter(sql: "issueTags LIKE '%\"partial\"%'"
                             + " OR (MAX(cropW,cropH) * 1.0 / MIN(cropW,cropH)) > 2.2"
                             + " OR cropW < 60 OR cropH < 60")
                .fetchCount(db),
            obscured: StampRecord
                .filter(sql: "issueTags LIKE '%\"obscured\"%'")
                .fetchCount(db),
            duplicates: StampRecord
                .filter(sql: "issueTags LIKE '%\"duplicate\"%'")
                .fetchCount(db),
            flagged: StampRecord
                .filter(StampRecord.Columns.flagged == true)
                .fetchCount(db)
        )
    }
}
