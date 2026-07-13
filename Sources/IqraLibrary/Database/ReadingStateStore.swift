import Foundation
import GRDB

/// Persistence for reading positions (spec "Identity, versioning & reading-state model").
/// The locator is an opaque JSON blob to this layer — IqraLibrary never imports reader
/// types. `highWaterMark` is merged by max and never regresses; the current locator moves
/// freely (a reader re-reading from 5% must not be dragged forward).
public final class ReadingStateStore: @unchecked Sendable {
    let dbm: DatabaseManager
    public init(dbm: DatabaseManager) { self.dbm = dbm }

    public func locatorJSON(bookID: UUID, formatID: UUID) throws -> Data? {
        try dbm.writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT currentLocator FROM reading_state WHERE bookId = ? AND formatId = ?
                """, arguments: [bookID.uuidString, formatID.uuidString])
                .map { Data($0.utf8) }
        }
    }

    public func highWaterMark(bookID: UUID, formatID: UUID) throws -> Double {
        try dbm.writer.read { db in
            try Double.fetchOne(db, sql: """
                SELECT highWaterMark FROM reading_state WHERE bookId = ? AND formatId = ?
                """, arguments: [bookID.uuidString, formatID.uuidString]) ?? 0
        }
    }

    @discardableResult
    public func saveLocator(json: Data, totalProgression: Double,
                            bookID: UUID, formatID: UUID) throws -> Double {
        try dbm.writer.write { db in
            let seq = try dbm.nextApplySequence(db)
            try db.execute(sql: """
                INSERT INTO reading_state (id, bookId, formatId, currentLocator, candidates,
                                           highWaterMark, applySeq)
                VALUES (?, ?, ?, ?, '[]', ?, ?)
                ON CONFLICT(bookId, formatId) DO UPDATE SET
                    currentLocator = excluded.currentLocator,
                    highWaterMark = MAX(reading_state.highWaterMark, excluded.highWaterMark),
                    applySeq = excluded.applySeq
                """, arguments: [UUID().uuidString, bookID.uuidString, formatID.uuidString,
                                 String(decoding: json, as: UTF8.self), totalProgression, seq])
            return try Double.fetchOne(db, sql: """
                SELECT highWaterMark FROM reading_state WHERE bookId = ? AND formatId = ?
                """, arguments: [bookID.uuidString, formatID.uuidString]) ?? totalProgression
        }
    }
}
