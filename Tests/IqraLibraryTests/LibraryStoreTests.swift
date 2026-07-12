import XCTest
import IqraCore
import GRDB
@testable import IqraLibrary

final class LibraryStoreTests: XCTestCase {
    var store: LibraryStore!
    var dbm: DatabaseManager!

    override func setUpWithError() throws {
        dbm = try DatabaseManager.inMemory()
        store = LibraryStore(dbm: dbm)
    }

    func insert(_ title: String, author: String, description: String = "") throws {
        let meta = ExtractedMetadata(
            title: title, titleSort: makeTitleSort(title, language: "en"), language: "en",
            publisher: nil, bookDescription: description,
            contributors: [Contributor(name: author,
                                       sortName: EPUBMetadataExtractor.makeAuthorSort(author),
                                       role: .author)],
            identifiers: [])
        try store.insertBook(metadata: meta, formatType: .epub, originalFileName: "\(title).epub",
                             byteSize: 1, contentHash: UUID().uuidString,
                             bookID: UUID(), formatID: UUID())
    }

    func testListSortsByTitleSort() throws {
        try insert("The Zebra Book", author: "Z Author")
        try insert("Apples", author: "A Author")
        let titles = try store.listBooks(sort: .titleSort).map(\.title)
        XCTAssertEqual(titles, ["Apples", "The Zebra Book"]) // "Zebra Book, The" sorts after "Apples"
    }

    func testFTSSearchMatchesTitleAuthorDescription() throws {
        try insert("The Dispossessed", author: "Ursula K. Le Guin", description: "An ambiguous utopia")
        try insert("Dune", author: "Frank Herbert", description: "Spice")
        XCTAssertEqual(try store.searchBooks("disposs").map(\.title), ["The Dispossessed"]) // prefix
        XCTAssertEqual(try store.searchBooks("guin").map(\.title), ["The Dispossessed"])    // author
        XCTAssertEqual(try store.searchBooks("utopia").map(\.title), ["The Dispossessed"])  // description
        XCTAssertEqual(try store.searchBooks("zzzz").count, 0)
    }

    func testObservationFiresOnInsert() throws {
        let expectation = expectation(description: "observed")
        expectation.expectedFulfillmentCount = 2 // initial + after insert
        var seen: [[BookListItem]] = []
        let cancellable = store.observeBooks(sort: .recentlyAdded).start(
            in: dbm.writer,
            onError: { XCTFail("\($0)") },
            onChange: { items in seen.append(items); expectation.fulfill() })
        try insert("New Arrival", author: "N. A.")
        wait(for: [expectation], timeout: 5)
        cancellable.cancel()
        XCTAssertEqual(seen.last?.map(\.title), ["New Arrival"])
    }

    /// Discriminates the bug: raw display-name order would put "Frank Herbert" (F),
    /// "Mary Shelley" (M), "Ursula K. Le Guin" (U) in that order. Sorting by the
    /// stored `sortName` ("Herbert, Frank" / "Le Guin, Ursula K." / "Shelley, Mary")
    /// moves Le Guin from last to the middle, which is the only way to tell the two
    /// implementations apart.
    func testAuthorSortOrdersByStoredSortNameNotDisplayName() throws {
        try insert("Dune", author: "Frank Herbert")
        try insert("Frankenstein", author: "Mary Shelley")
        try insert("The Dispossessed", author: "Ursula K. Le Guin")

        let titles = try store.listBooks(sort: .authorSort).map(\.title)
        XCTAssertEqual(titles, ["Dune", "The Dispossessed", "Frankenstein"])
    }

    /// `group_concat` without an ORDER BY only happens to follow ordinal today because
    /// the insert path writes rows in ordinal order. This test scrambles the physical
    /// (rowid) order of `book_contributor` rows after insert, while preserving their
    /// `ordinal` values, proving that author display order must be derived from
    /// `ordinal` rather than from insertion/rowid order.
    func testListBooksAuthorOrderFollowsOrdinalsRegardlessOfPhysicalRowOrder() throws {
        let bookID = UUID()
        let meta = ExtractedMetadata(
            title: "Anthology", titleSort: makeTitleSort("Anthology", language: "en"), language: "en",
            publisher: nil, bookDescription: "",
            contributors: [
                Contributor(name: "First", sortName: EPUBMetadataExtractor.makeAuthorSort("First"), role: .author),
                Contributor(name: "Second", sortName: EPUBMetadataExtractor.makeAuthorSort("Second"), role: .author),
                Contributor(name: "Third", sortName: EPUBMetadataExtractor.makeAuthorSort("Third"), role: .author),
            ],
            identifiers: [])
        try store.insertBook(metadata: meta, formatType: .epub, originalFileName: "Anthology.epub",
                             byteSize: 1, contentHash: UUID().uuidString,
                             bookID: bookID, formatID: UUID())

        try dbm.writer.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, bookId, contributorId, role, ordinal FROM book_contributor
                WHERE bookId = ? ORDER BY ordinal
                """, arguments: [bookID.uuidString])
            try db.execute(sql: "DELETE FROM book_contributor WHERE bookId = ?", arguments: [bookID.uuidString])
            // Re-insert in reverse ordinal order, so physical/rowid order is the exact
            // opposite of ordinal order, while ordinal values themselves are unchanged.
            for row in rows.reversed() {
                let id: String = row["id"]
                let bookId: String = row["bookId"]
                let contributorId: String = row["contributorId"]
                let role: String = row["role"]
                let ordinal: Int = row["ordinal"]
                try db.execute(sql: """
                    INSERT INTO book_contributor (id, bookId, contributorId, role, ordinal)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [id, bookId, contributorId, role, ordinal])
            }
        }

        let authors = try store.listBooks(sort: .titleSort).first?.authors
        XCTAssertEqual(authors, "First, Second, Third")
    }

    func testQuarantinedItems() throws {
        try dbm.writer.write { db in
            try ImportItemRecord(id: UUID().uuidString, sourceBookmark: nil,
                                 sourceDisplayPath: "/x/locked.epub", status: "quarantined",
                                 rejection: "drmProtected", message: nil, attemptCount: 1,
                                 createdAt: Date(), updatedAt: Date(), bookId: nil).insert(db)
        }
        let items = try store.quarantinedItems()
        XCTAssertEqual(items.map(\.rejection), ["drmProtected"])
    }
}
