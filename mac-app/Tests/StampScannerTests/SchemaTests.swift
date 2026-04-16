import XCTest
import GRDB
@testable import StampScanner

/// Verifies that StampRecord round-trips cleanly through the live GRDB
/// schema. Catches silent encode/decode drift — e.g. a field added to the
/// struct but forgotten in encode(to:) or init(row:).
///
/// Uses a temp-file DatabasePool with the real migrator, so schema changes
/// are exercised end-to-end.
final class SchemaTests: XCTestCase {
    var dbURL: URL!
    var pool: DatabasePool!

    override func setUp() async throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("schematest-\(UUID().uuidString).sqlite")
        pool = try await MainActor.run { try DatabasePool(path: dbURL.path) }
        try await MainActor.run { try LibraryDatabase.migrator.migrate(pool) }
    }

    override func tearDown() {
        pool = nil
        try? FileManager.default.removeItem(at: dbURL)
        // GRDB's WAL/SHM siblings
        try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: dbURL.appendingPathExtension("shm"))
    }

    func testRoundTripWithEveryFieldPopulated() throws {
        let input = StampRecord(
            id: "test-01",
            capturedAt: Date(timeIntervalSince1970: 1_776_000_000),
            cropPath: "test-01/crop.png",
            sourceFramePath: "_sources/test-01.jpg",
            confidence: 0.923,
            cropW: 640,
            cropH: 880,
            quadFlat: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0],
            country: "Australia",
            year: 1985,
            denomination: "30c",
            colour: "red",
            subject: "Russell Drysdale painting",
            series: "Australia Day 1985",
            used: true,
            cancelType: "CDS",
            printing: "lithograph",
            overprint: nil,
            description: "Australia Day commemorative",
            perfGauge: "14",
            watermark: "none",
            gum: "NG",
            condition: "VF",
            catalogueRef: "SG 950",
            notes: "minor corner crease",
            flagged: true,
            jobId: "job-123",
            perceptualHash: Int64.max - 42,
            oriented: true,
            rotationVersion: 3,
            issueTags: ["duplicate", "obscured"],
            duplicateOf: "test-00"
        )

        try pool.write { db in try input.insert(db) }
        let fetched = try pool.read { db in
            try StampRecord.fetchOne(db, key: "test-01")
        }
        guard let output = fetched else {
            XCTFail("Record not found after insert"); return
        }

        XCTAssertEqual(input.id, output.id)
        XCTAssertEqual(input.capturedAt.timeIntervalSince1970,
                        output.capturedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(input.cropPath, output.cropPath)
        XCTAssertEqual(input.sourceFramePath, output.sourceFramePath)
        XCTAssertEqual(input.confidence, output.confidence, accuracy: 1e-6)
        XCTAssertEqual(input.cropW, output.cropW)
        XCTAssertEqual(input.cropH, output.cropH)
        XCTAssertEqual(input.quadFlat, output.quadFlat)
        XCTAssertEqual(input.country, output.country)
        XCTAssertEqual(input.year, output.year)
        XCTAssertEqual(input.denomination, output.denomination)
        XCTAssertEqual(input.colour, output.colour)
        XCTAssertEqual(input.subject, output.subject)
        XCTAssertEqual(input.series, output.series)
        XCTAssertEqual(input.used, output.used)
        XCTAssertEqual(input.cancelType, output.cancelType)
        XCTAssertEqual(input.printing, output.printing)
        XCTAssertEqual(input.overprint, output.overprint)
        XCTAssertEqual(input.description, output.description)
        XCTAssertEqual(input.perfGauge, output.perfGauge)
        XCTAssertEqual(input.watermark, output.watermark)
        XCTAssertEqual(input.gum, output.gum)
        XCTAssertEqual(input.condition, output.condition)
        XCTAssertEqual(input.catalogueRef, output.catalogueRef)
        XCTAssertEqual(input.notes, output.notes)
        XCTAssertEqual(input.flagged, output.flagged)
        XCTAssertEqual(input.jobId, output.jobId)
        XCTAssertEqual(input.perceptualHash, output.perceptualHash)
        XCTAssertEqual(input.oriented, output.oriented)
        XCTAssertEqual(input.rotationVersion, output.rotationVersion)
        XCTAssertEqual(input.issueTags, output.issueTags)
        XCTAssertEqual(input.duplicateOf, output.duplicateOf)
    }

    func testRoundTripWithAllOptionalsNil() throws {
        let input = StampRecord(
            id: "bare-01",
            capturedAt: Date(),
            cropPath: "bare-01/crop.png",
            sourceFramePath: nil,
            confidence: 0.5,
            cropW: 200, cropH: 250,
            quadFlat: []
        )
        try pool.write { db in try input.insert(db) }
        let output = try pool.read { db in
            try StampRecord.fetchOne(db, key: "bare-01")
        }
        XCTAssertNotNil(output)
        XCTAssertNil(output?.country)
        XCTAssertNil(output?.sourceFramePath)
        XCTAssertEqual(output?.issueTags, [])
        XCTAssertEqual(output?.flagged, false)
        XCTAssertEqual(output?.jobId, "")
    }

    func testIssueTagsJSONIsValidSQL() throws {
        // Verify the `LIKE '%"duplicate"%'` query pattern works as expected.
        let recs = [
            StampRecord(id: "a", capturedAt: Date(), cropPath: "a/c.png",
                         sourceFramePath: nil, confidence: 0.9,
                         cropW: 100, cropH: 100, quadFlat: [],
                         issueTags: ["duplicate"]),
            StampRecord(id: "b", capturedAt: Date(), cropPath: "b/c.png",
                         sourceFramePath: nil, confidence: 0.9,
                         cropW: 100, cropH: 100, quadFlat: [],
                         issueTags: ["obscured", "partial"]),
            StampRecord(id: "c", capturedAt: Date(), cropPath: "c/c.png",
                         sourceFramePath: nil, confidence: 0.9,
                         cropW: 100, cropH: 100, quadFlat: [],
                         issueTags: []),
        ]
        try pool.write { db in for r in recs { try r.insert(db) } }
        let dups = try pool.read { db in
            try StampRecord
                .filter(sql: "issueTags LIKE '%\"duplicate\"%'")
                .fetchAll(db)
        }
        XCTAssertEqual(dups.map(\.id), ["a"])

        let obscured = try pool.read { db in
            try StampRecord
                .filter(sql: "issueTags LIKE '%\"obscured\"%'")
                .fetchAll(db)
        }
        XCTAssertEqual(obscured.map(\.id), ["b"])
    }
}
