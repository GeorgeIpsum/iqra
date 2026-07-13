import Foundation
import GRDB

/// Persistence for EPUB annotations (spec "Annotations rendering"). The locator is opaque
/// JSON to this layer — IqraLibrary never imports reader types. Deletes are permanent
/// tombstones; every write stamps a fresh apply sequence.
public final class AnnotationStore: @unchecked Sendable {
    let dbm: DatabaseManager
    public init(dbm: DatabaseManager) { self.dbm = dbm }

    public func upsert(id: UUID, bookID: UUID, formatID: UUID, kind: String,
                       locatorJSON: Data, color: String?, noteText: String?) throws {
        try dbm.writer.write { db in
            let seq = try dbm.nextApplySequence(db)
            let now = Date()
            let locator = String(decoding: locatorJSON, as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO annotation (id, bookId, formatId, kind, locator, color, noteText,
                                        createdAt, modifiedAt, applySeq, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind, locator = excluded.locator, color = excluded.color,
                    noteText = excluded.noteText, modifiedAt = excluded.modifiedAt,
                    applySeq = excluded.applySeq
                """, arguments: [id.uuidString, bookID.uuidString, formatID.uuidString, kind,
                                 locator, color, noteText, now, now, seq])
        }
    }

    public func delete(id: UUID) throws {
        try dbm.writer.write { db in
            let seq = try dbm.nextApplySequence(db)
            try db.execute(sql: """
                UPDATE annotation SET deleted = 1, modifiedAt = ?, applySeq = ? WHERE id = ?
                """, arguments: [Date(), seq, id.uuidString])
        }
    }

    public func annotation(id: UUID) throws -> AnnotationRecord? {
        try dbm.writer.read { db in try AnnotationRecord.fetchOne(db, key: id.uuidString) }
    }

    // Orders by the stored locator's spineIndex then totalProgression via JSON1 —
    // no Swift decode, no schema change (the reader Locator carries both fields).
    private static let orderedSQL = """
        SELECT * FROM annotation
        WHERE bookId = ? AND formatId = ? AND deleted = 0
        ORDER BY CAST(json_extract(locator, '$.spineIndex') AS INTEGER) ASC,
                 CAST(json_extract(locator, '$.totalProgression') AS REAL) ASC,
                 createdAt ASC
        """

    public func annotations(bookID: UUID, formatID: UUID) throws -> [AnnotationRecord] {
        try dbm.writer.read { db in
            try AnnotationRecord.fetchAll(db, sql: Self.orderedSQL,
                                          arguments: [bookID.uuidString, formatID.uuidString])
        }
    }

    public func observeAnnotations(bookID: UUID, formatID: UUID)
        -> ValueObservation<ValueReducers.Fetch<[AnnotationRecord]>> {
        ValueObservation.tracking { db in
            try AnnotationRecord.fetchAll(db, sql: Self.orderedSQL,
                                          arguments: [bookID.uuidString, formatID.uuidString])
        }
    }
}
