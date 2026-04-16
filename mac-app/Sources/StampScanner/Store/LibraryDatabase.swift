import Foundation
import GRDB

/// Single writer `DatabasePool` for the app. External tools (sqlite3 CLI,
/// DataGrip, Python scripts) can open the same file concurrently in
/// reader mode thanks to WAL; the app takes the write lock only inside
/// `write { }` closures, which are short.
@MainActor
enum LibraryDatabase {
    // swiftlint:disable force_try
    // App-bootstrap: if any of these fail the app cannot function, so
    // crashing is the correct response (no meaningful recovery path).
    static let shared: DatabasePool = {
        try! FileManager.default.createDirectory(
            at: Paths.appSupport, withIntermediateDirectories: true)
        // Default configuration enables WAL automatically for pools.
        var config = Configuration()
        config.label = "StampScannerLibrary"
        let pool = try! DatabasePool(path: Paths.sqliteFile.path, configuration: config)
        try! migrator.migrate(pool)
        return pool
    }()
    // swiftlint:enable force_try

    /// Schema migrations. Add cases here — never edit an existing one.
    /// `internal` so tests can apply the live schema to a throwaway DB.
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1_stamps") { db in
            try db.create(table: "stamps", ifNotExists: true) { t in
                t.primaryKey("id", .text).notNull()
                t.column("capturedAt", .datetime).notNull().indexed()
                t.column("cropPath", .text).notNull()
                t.column("sourceFramePath", .text)
                t.column("confidence", .double).notNull()
                t.column("cropW", .integer).notNull()
                t.column("cropH", .integer).notNull()
                t.column("quadFlat", .text).notNull()       // JSON array
                t.column("country", .text)
                t.column("year", .integer)
                t.column("denomination", .text)
                t.column("notes", .text)
                t.column("flagged", .boolean).notNull().defaults(to: false)
                t.column("jobId", .text).notNull().defaults(to: "")
            }
            try db.create(index: "idx_stamps_jobId", on: "stamps",
                          columns: ["jobId"], ifNotExists: true)
            try db.create(index: "idx_stamps_flagged", on: "stamps",
                          columns: ["flagged"], ifNotExists: true)
        }
        m.registerMigration("v2_perceptualHash") { db in
            let columns = try db.columns(in: "stamps").map(\.name)
            if !columns.contains("perceptualHash") {
                try db.alter(table: "stamps") { t in
                    t.add(column: "perceptualHash", .integer)
                }
            }
        }
        m.registerMigration("v3_oriented") { db in
            let columns = try db.columns(in: "stamps").map(\.name)
            if !columns.contains("oriented") {
                try db.alter(table: "stamps") { t in
                    t.add(column: "oriented", .boolean).notNull().defaults(to: false)
                }
            }
        }
        m.registerMigration("v5_rotationVersion") { db in
            let columns = try db.columns(in: "stamps").map(\.name)
            if !columns.contains("rotationVersion") {
                try db.alter(table: "stamps") { t in
                    t.add(column: "rotationVersion", .integer).notNull().defaults(to: 0)
                }
            }
        }
        m.registerMigration("v6_issueTags") { db in
            let columns = try db.columns(in: "stamps").map(\.name)
            if !columns.contains("issueTags") {
                try db.alter(table: "stamps") { t in
                    t.add(column: "issueTags", .text).notNull().defaults(to: "[]")
                }
            }
            if !columns.contains("duplicateOf") {
                try db.alter(table: "stamps") { t in
                    t.add(column: "duplicateOf", .text)
                }
            }
        }
        m.registerMigration("v7_dismissedIssueTags") { db in
            let columns = try db.columns(in: "stamps").map(\.name)
            if !columns.contains("dismissedIssueTags") {
                try db.alter(table: "stamps") { t in
                    t.add(column: "dismissedIssueTags", .text)
                        .notNull().defaults(to: "[]")
                }
            }
        }
        m.registerMigration("v4_philatelic_fields") { db in
            let columns = try db.columns(in: "stamps").map(\.name)
            let additions: [(String, Database.ColumnType)] = [
                ("colour", .text),
                ("subject", .text),
                ("series", .text),
                ("used", .boolean),
                ("cancelType", .text),
                ("printing", .text),
                ("overprint", .text),
                ("description", .text),
                ("perfGauge", .text),
                ("watermark", .text),
                ("gum", .text),
                ("condition", .text),
                ("catalogueRef", .text),
            ]
            for (name, type) in additions {
                if !columns.contains(name) {
                    try db.alter(table: "stamps") { t in
                        t.add(column: name, type)
                    }
                }
            }
        }
        return m
    }
}

extension Paths {
    /// Where the library SQLite file lives. Deliberately a stable public
    /// path so external tools (Python, DataGrip, sqlite3 CLI) can find it.
    static var sqliteFile: URL {
        appSupport.appendingPathComponent("library.sqlite")
    }
}
