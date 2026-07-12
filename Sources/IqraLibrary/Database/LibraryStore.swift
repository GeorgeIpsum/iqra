import Foundation
import GRDB
import IqraCore

public final class LibraryStore: @unchecked Sendable {
    public let dbm: DatabaseManager
    public init(dbm: DatabaseManager) { self.dbm = dbm }

    @discardableResult
    public func insertBook(metadata: ExtractedMetadata, formatType: FormatType,
                           originalFileName: String, byteSize: Int64, contentHash: String,
                           bookID: UUID, formatID: UUID) throws -> (bookID: UUID, formatID: UUID) {
        try dbm.writer.write { db in
            let now = Date()
            let bookSeq = try dbm.nextApplySequence(db)
            try BookRecord(
                id: bookID.uuidString, title: metadata.title, titleSort: metadata.titleSort,
                bookDescription: metadata.bookDescription, publisher: metadata.publisher,
                pubDate: nil, language: metadata.language, seriesId: nil, seriesIndex: nil,
                wantToRead: false, isFinished: false, dateFinished: nil, lastOpenedAt: nil,
                addedAt: now, applySeq: bookSeq, deleted: false
            ).insert(db)

            for (ordinal, c) in metadata.contributors.enumerated() {
                let contributorId: String
                if let existing = try String.fetchOne(
                    db, sql: "SELECT id FROM contributor WHERE name = ?", arguments: [c.name]) {
                    contributorId = existing
                } else {
                    contributorId = UUID().uuidString
                    let seq = try dbm.nextApplySequence(db)
                    try db.execute(
                        sql: "INSERT INTO contributor (id, name, sortName, applySeq) VALUES (?, ?, ?, ?)",
                        arguments: [contributorId, c.name, c.sortName, seq])
                }
                try db.execute(
                    sql: """
                    INSERT INTO book_contributor (id, bookId, contributorId, role, ordinal)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [UUID().uuidString, bookID.uuidString, contributorId, c.role.rawValue, ordinal])
            }

            for ident in metadata.identifiers {
                try db.execute(
                    sql: "INSERT INTO identifier (id, bookId, type, value) VALUES (?, ?, ?, ?)",
                    arguments: [UUID().uuidString, bookID.uuidString, ident.type, ident.value])
            }

            let formatSeq = try dbm.nextApplySequence(db)
            try FormatRecord(
                id: formatID.uuidString, bookId: bookID.uuidString, formatType: formatType.rawValue,
                originalFileName: originalFileName, byteSize: byteSize, contentHash: contentHash,
                addedAt: now, applySeq: formatSeq, deleted: false
            ).insert(db)
            try db.execute(
                sql: "INSERT INTO format_local (formatId, present, localVerifiedAt, missing) VALUES (?, 1, ?, 0)",
                arguments: [formatID.uuidString, now])

            let authors = metadata.contributors.filter { $0.role == .author }.map(\.name)
            try db.execute(
                sql: """
                INSERT INTO fts.book_fts (bookId, title, authors, series, tags, description)
                VALUES (?, ?, ?, '', '', ?)
                """,
                arguments: [bookID.uuidString, metadata.title,
                            authors.joined(separator: ", "), metadata.bookDescription ?? ""])
            return (bookID, formatID)
        }
    }

    public func fetchBook(_ id: UUID) throws -> BookRecord? {
        try dbm.writer.read { db in try BookRecord.fetchOne(db, key: id.uuidString) }
    }

    public func fetchFormats(bookID: UUID) throws -> [FormatRecord] {
        try dbm.writer.read { db in
            try FormatRecord
                .filter(Column("bookId") == bookID.uuidString && Column("deleted") == false)
                .fetchAll(db)
        }
    }

    public func fetchAuthors(bookID: UUID) throws -> [String] {
        try dbm.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT c.name FROM contributor c
                JOIN book_contributor bc ON bc.contributorId = c.id
                WHERE bc.bookId = ? AND bc.role = 'author'
                ORDER BY bc.ordinal
                """, arguments: [bookID.uuidString])
        }
    }
}
