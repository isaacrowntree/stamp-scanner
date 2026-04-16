import Foundation
import GRDB

struct StampRecord: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var capturedAt: Date
    var cropPath: String
    var sourceFramePath: String?
    var confidence: Double
    var cropW: Int
    var cropH: Int
    var quadFlat: [Double]          // JSON-encoded for SQLite

    // -- VLM-fillable identification --
    var country: String?
    var year: Int?
    var denomination: String?
    var colour: String?             // "red-brown", "blue", "multicolour"
    var subject: String?            // "King George V", "Statue of Liberty"
    var series: String?             // "Christmas 1978", "Definitive"
    var used: Bool?                 // nil=unknown, true=used, false=mint
    var cancelType: String?         // "CDS", "machine", "pen"
    var printing: String?           // "engraved", "lithograph", "photogravure"
    var overprint: String?          // text of overprint, nil if none
    var description: String?        // free-text VLM description

    // -- Manual / algorithmic (filled later) --
    var perfGauge: String?          // "14", "13½x14"
    var watermark: String?          // "Crown over A", "none"
    var gum: String?                // "MNH", "LH", "OG", "NG"
    var condition: String?          // "XF", "VF", "F", "AVG"
    var catalogueRef: String?       // "SG 100", "Scott 1234"
    var notes: String?              // free-text user notes

    // -- Curation --
    var flagged: Bool = false
    var jobId: String = ""
    var perceptualHash: Int64?
    var oriented: Bool = false
    /// Increments each time the user manually rotates the crop. Used as a
    /// cache buster for SwiftUI's AsyncImage so it re-reads the PNG from
    /// disk after we rewrite it.
    var rotationVersion: Int = 0

    var cropURL: URL {
        Paths.capturesDir.appendingPathComponent(cropPath)
    }

    /// Cache-busting URL used by AsyncImage in views. The Python
    /// orientation worker rewrites the crop file in-place; SwiftUI's
    /// AsyncImage caches by URL string so we append a query param that
    /// changes once the orientation pass has run. This forces a re-fetch
    /// from disk after rotation without us needing an explicit invalidator.
    var cropDisplayURL: URL {
        let base = cropURL
        return URL(string: base.absoluteString + "?v=\(rotationVersion)") ?? base
    }

    var sourceURL: URL? {
        sourceFramePath.map { Paths.capturesDir.appendingPathComponent($0) }
    }
}

extension StampRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "stamps"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let capturedAt = Column(CodingKeys.capturedAt)
        static let cropPath = Column(CodingKeys.cropPath)
        static let sourceFramePath = Column(CodingKeys.sourceFramePath)
        static let confidence = Column(CodingKeys.confidence)
        static let cropW = Column(CodingKeys.cropW)
        static let cropH = Column(CodingKeys.cropH)
        static let quadFlat = Column(CodingKeys.quadFlat)
        static let country = Column(CodingKeys.country)
        static let year = Column(CodingKeys.year)
        static let denomination = Column(CodingKeys.denomination)
        static let colour = Column(CodingKeys.colour)
        static let subject = Column(CodingKeys.subject)
        static let series = Column(CodingKeys.series)
        static let used = Column(CodingKeys.used)
        static let cancelType = Column(CodingKeys.cancelType)
        static let printing = Column(CodingKeys.printing)
        static let overprint = Column(CodingKeys.overprint)
        static let description = Column(CodingKeys.description)
        static let perfGauge = Column(CodingKeys.perfGauge)
        static let watermark = Column(CodingKeys.watermark)
        static let gum = Column(CodingKeys.gum)
        static let condition = Column(CodingKeys.condition)
        static let catalogueRef = Column(CodingKeys.catalogueRef)
        static let notes = Column(CodingKeys.notes)
        static let flagged = Column(CodingKeys.flagged)
        static let jobId = Column(CodingKeys.jobId)
        static let perceptualHash = Column(CodingKeys.perceptualHash)
        static let oriented = Column(CodingKeys.oriented)
        static let rotationVersion = Column(CodingKeys.rotationVersion)
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.capturedAt] = capturedAt
        container[Columns.cropPath] = cropPath
        container[Columns.sourceFramePath] = sourceFramePath
        container[Columns.confidence] = confidence
        container[Columns.cropW] = cropW
        container[Columns.cropH] = cropH
        container[Columns.quadFlat] = (try? JSONEncoder().encode(quadFlat))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        container[Columns.country] = country
        container[Columns.year] = year
        container[Columns.denomination] = denomination
        container[Columns.colour] = colour
        container[Columns.subject] = subject
        container[Columns.series] = series
        container[Columns.used] = used
        container[Columns.cancelType] = cancelType
        container[Columns.printing] = printing
        container[Columns.overprint] = overprint
        container[Columns.description] = description
        container[Columns.perfGauge] = perfGauge
        container[Columns.watermark] = watermark
        container[Columns.gum] = gum
        container[Columns.condition] = condition
        container[Columns.catalogueRef] = catalogueRef
        container[Columns.notes] = notes
        container[Columns.flagged] = flagged
        container[Columns.jobId] = jobId
        container[Columns.perceptualHash] = perceptualHash
        container[Columns.oriented] = oriented
        container[Columns.rotationVersion] = rotationVersion
    }

    init(row: Row) throws {
        id = row[Columns.id]
        capturedAt = row[Columns.capturedAt]
        cropPath = row[Columns.cropPath]
        sourceFramePath = row[Columns.sourceFramePath]
        confidence = row[Columns.confidence]
        cropW = row[Columns.cropW]
        cropH = row[Columns.cropH]
        let quadStr: String = row[Columns.quadFlat] ?? "[]"
        quadFlat = (try? JSONDecoder().decode([Double].self,
                                              from: Data(quadStr.utf8))) ?? []
        country = row[Columns.country]
        year = row[Columns.year]
        denomination = row[Columns.denomination]
        colour = row[Columns.colour]
        subject = row[Columns.subject]
        series = row[Columns.series]
        used = row[Columns.used]
        cancelType = row[Columns.cancelType]
        printing = row[Columns.printing]
        overprint = row[Columns.overprint]
        description = row[Columns.description]
        perfGauge = row[Columns.perfGauge]
        watermark = row[Columns.watermark]
        gum = row[Columns.gum]
        condition = row[Columns.condition]
        catalogueRef = row[Columns.catalogueRef]
        notes = row[Columns.notes]
        flagged = row[Columns.flagged]
        jobId = row[Columns.jobId] ?? ""
        perceptualHash = row[Columns.perceptualHash]
        oriented = row[Columns.oriented] ?? false
        rotationVersion = row[Columns.rotationVersion] ?? 0
    }
}
