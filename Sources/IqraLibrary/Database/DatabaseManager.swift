import Foundation
import GRDB

/// Owns the catalogue database (WAL) with the FTS index ATTACHed as a separate,
/// rebuildable file (spec: calibre's pattern). All schema lives in migrations.
public final class DatabaseManager: @unchecked Sendable {
    public let writer: any DatabaseWriter

    public convenience init(catalogueURL: URL, ftsURL: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "ATTACH DATABASE ? AS fts", arguments: [ftsURL.path])
        }
        let pool = try DatabasePool(path: catalogueURL.path, configuration: config)
        try self.init(writer: pool)
    }

    /// Test convenience: in-memory catalogue with a throwaway on-disk FTS file
    /// (ATTACH needs a path; the temp file is per-instance).
    public static func inMemory() throws -> DatabaseManager {
        let ftsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fts-\(UUID().uuidString).sqlite")
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "ATTACH DATABASE ? AS fts", arguments: [ftsURL.path])
        }
        let queue = try DatabaseQueue(configuration: config)
        return try DatabaseManager(writer: queue)
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public func nextApplySequence(_ db: Database) throws -> Int64 {
        try db.execute(sql: "UPDATE apply_sequence SET value = value + 1")
        return try Int64.fetchOne(db, sql: "SELECT value FROM apply_sequence")!
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            // ---- catalogue-local apply sequence (spec "three clocks") ----
            try db.execute(sql: "CREATE TABLE apply_sequence (value INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO apply_sequence (value) VALUES (0)")

            try db.create(table: "series") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("sortName", .text).notNull()
                t.column("applySeq", .integer).notNull()
            }
            try db.create(table: "book") { t in
                t.primaryKey("id", .text)                       // UUID string
                t.column("title", .text).notNull()
                t.column("titleSort", .text).notNull().indexed()
                t.column("bookDescription", .text)
                t.column("publisher", .text)
                t.column("pubDate", .text)
                t.column("language", .text)
                t.column("seriesId", .text).references("series")
                t.column("seriesIndex", .double)                // REAL: fractional indices
                t.column("wantToRead", .boolean).notNull().defaults(to: false)
                t.column("isFinished", .boolean).notNull().defaults(to: false)
                t.column("dateFinished", .datetime)
                t.column("lastOpenedAt", .datetime)
                t.column("addedAt", .datetime).notNull()
                t.column("applySeq", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false) // permanent tombstone
            }
            try db.create(table: "contributor") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("sortName", .text).notNull()
                t.column("applySeq", .integer).notNull()
            }
            try db.create(table: "book_contributor") { t in
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("contributorId", .text).notNull().indexed().references("contributor")
                t.column("role", .text).notNull()               // author/translator/narrator/editor
                t.column("ordinal", .integer).notNull()
            }
            try db.create(table: "tag") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("applySeq", .integer).notNull()
            }
            try db.create(table: "book_tag") { t in
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("tagId", .text).notNull().indexed().references("tag")
            }
            try db.create(table: "identifier") { t in         // open bag, never an isbn column
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("value", .text).notNull().indexed()
            }
            try db.create(table: "format") { t in
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("formatType", .text).notNull()
                t.column("originalFileName", .text).notNull()   // export/reveal only; stored file is <formatUUID>.<ext>
                t.column("byteSize", .integer).notNull()
                t.column("contentHash", .text).notNull().indexed() // SHA-256 hex; identity + dedupe + merge key
                t.column("addedAt", .datetime).notNull()
                t.column("applySeq", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "format_local") { t in        // per-device availability; NEVER synced
                t.primaryKey("formatId", .text).references("format")
                t.column("present", .boolean).notNull()
                t.column("localVerifiedAt", .datetime)
                t.column("missing", .boolean).notNull().defaults(to: false) // row exists but folder lost (reconciliation)
            }
            try db.create(table: "collection") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("smartRule", .text)                    // JSON; NULL = manual
                t.column("applySeq", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "collection_book") { t in     // first-class synced membership record
                t.primaryKey("id", .text)
                t.column("collectionId", .text).notNull().indexed().references("collection")
                t.column("bookId", .text).notNull().indexed().references("book")
                t.column("orderKey", .text).notNull()           // fractional / LexoRank-style
                t.column("applySeq", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "field_lock") { t in          // one record per locked field (reviewed: no JSON blob)
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("field", .text).notNull()
                t.column("locked", .boolean).notNull()
                t.column("applySeq", .integer).notNull()
                t.uniqueKey(["bookId", "field"])
            }
            try db.create(table: "reading_state") { t in       // per (book, format); device tags live INSIDE locator JSON
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("formatId", .text).notNull().indexed().references("format")
                t.column("currentLocator", .text)               // JSON {locator, deviceId, deviceName, localCounter, advisoryTime}
                t.column("candidates", .text).notNull().defaults(to: "[]") // durable conflict candidates, same shape
                t.column("highWaterMark", .double).notNull().defaults(to: 0)
                t.column("applySeq", .integer).notNull()
                t.uniqueKey(["bookId", "formatId"])
            }
            try db.create(table: "annotation") { t in
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("formatId", .text).notNull().references("format")
                t.column("kind", .text).notNull()               // highlight/note/bookmark
                t.column("locator", .text).notNull()            // JSON: range CFI or PDF quads
                t.column("color", .text)
                t.column("noteText", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("applySeq", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false) // tombstone: monotonic, never GCed
            }
            try db.create(table: "import_item") { t in         // local-only durable import/quarantine state
                t.primaryKey("id", .text)
                t.column("sourceBookmark", .blob)               // security-scoped bookmark
                t.column("sourceDisplayPath", .text).notNull()
                t.column("status", .text).notNull()             // pending/importing/quarantined/failed/done
                t.column("rejection", .text)                    // ImportRejection raw value
                t.column("message", .text)
                t.column("attemptCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("bookId", .text)                       // nullable resulting book
            }
            // ---- FTS5 metadata index in the ATTACHed db (rebuildable) ----
            try db.execute(sql: """
                CREATE VIRTUAL TABLE fts.book_fts USING fts5(
                    bookId UNINDEXED, title, authors, series, tags, description,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """)
        }
        return m
    }
}
