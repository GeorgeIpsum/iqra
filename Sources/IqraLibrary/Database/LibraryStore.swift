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

public struct BookListItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let authors: String
    public let addedAt: Date
}

public enum BookSort: String, CaseIterable, Sendable {
    case titleSort, recentlyAdded, authorSort

    var sql: String {
        switch self {
        case .titleSort: "b.titleSort COLLATE NOCASE ASC"
        case .recentlyAdded: "b.addedAt DESC"
        case .authorSort:
            // NULL authorSortKey (books with no author) sorts last, deterministically.
            "(authorSortKey IS NULL) ASC, authorSortKey COLLATE NOCASE ASC, b.titleSort COLLATE NOCASE ASC"
        }
    }
}

extension LibraryStore {
    // Both `authors` and `authorSortKey` are derived from correlated subqueries over
    // book_contributor rows ordered by `ordinal`, rather than a flat LEFT JOIN +
    // group_concat: group_concat has no ordering guarantee of its own (it happens to
    // follow rowid/insertion order), and the display name is not a valid sort key
    // (e.g. "Ursula K. Le Guin" must sort under "Le Guin", not "Ursula").
    private static let listSQL = """
        SELECT b.id AS id, b.title AS title, b.addedAt AS addedAt,
               COALESCE((
                   SELECT group_concat(name, ', ') FROM (
                       SELECT c.name AS name
                       FROM book_contributor bc
                       JOIN contributor c ON c.id = bc.contributorId
                       WHERE bc.bookId = b.id AND bc.role = 'author'
                       ORDER BY bc.ordinal
                   )
               ), '') AS authors,
               (
                   SELECT c.sortName
                   FROM book_contributor bc
                   JOIN contributor c ON c.id = bc.contributorId
                   WHERE bc.bookId = b.id AND bc.role = 'author'
                   ORDER BY bc.ordinal LIMIT 1
               ) AS authorSortKey
        FROM book b
        WHERE b.deleted = 0 %WHERE%
        """

    private static func mapItems(_ rows: [Row]) -> [BookListItem] {
        rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            return BookListItem(id: id, title: row["title"], authors: row["authors"],
                                addedAt: row["addedAt"])
        }
    }

    /// Assembles the shared list query: substitutes an extra WHERE clause (or "") into
    /// `listSQL` and appends an ORDER BY. Used by `listBooks`, `searchBooks`, and
    /// `observeBooks` so the query shape stays in one place.
    private static func assembleSQL(extraWhere: String = "", orderBy: String) -> String {
        listSQL.replacingOccurrences(of: "%WHERE%", with: extraWhere) + " ORDER BY \(orderBy)"
    }

    public func listBooks(sort: BookSort) throws -> [BookListItem] {
        try dbm.writer.read { db in
            let sql = Self.assembleSQL(orderBy: sort.sql)
            return Self.mapItems(try Row.fetchAll(db, sql: sql))
        }
    }

    public func searchBooks(_ query: String) throws -> [BookListItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try listBooks(sort: .titleSort) }
        // quote each token and add prefix-match star; quoting neutralizes FTS operators in user input
        let match = trimmed.split(separator: " ")
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " ")
        return try dbm.writer.read { db in
            let sql = Self.assembleSQL(
                extraWhere: "AND b.id IN (SELECT bookId FROM fts.book_fts WHERE book_fts MATCH ?)",
                orderBy: "b.titleSort COLLATE NOCASE ASC")
            return Self.mapItems(try Row.fetchAll(db, sql: sql, arguments: [match]))
        }
    }

    public func quarantinedItems() throws -> [ImportItemRecord] {
        try dbm.writer.read { db in
            // 'failed' is intentionally included alongside 'quarantined': the recovery
            // UI surfaces both so the user can retry or resolve import failures.
            try ImportItemRecord
                .filter(Column("status") == "quarantined" || Column("status") == "failed")
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    public func observeBooks(sort: BookSort) -> ValueObservation<ValueReducers.Fetch<[BookListItem]>> {
        ValueObservation.tracking { db in
            let sql = Self.assembleSQL(orderBy: sort.sql)
            return Self.mapItems(try Row.fetchAll(db, sql: sql))
        }
    }
}
