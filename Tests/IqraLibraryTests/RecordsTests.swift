import XCTest
import IqraCore
@testable import IqraLibrary

final class RecordsTests: XCTestCase {
    func makeMetadata() -> ExtractedMetadata {
        ExtractedMetadata(
            title: "The Dispossessed", titleSort: makeTitleSort("The Dispossessed", language: "en"),
            language: "en", publisher: "Harper", bookDescription: "An ambiguous utopia.",
            contributors: [Contributor(name: "Ursula K. Le Guin", sortName: "Le Guin, Ursula K.", role: .author)],
            identifiers: [BookIdentifier(type: "isbn", value: "9780060512750")]
        )
    }

    func testInsertBookRoundTrip() throws {
        let dbm = try DatabaseManager.inMemory()
        let store = LibraryStore(dbm: dbm)
        let bookID = UUID(), formatID = UUID()
        try store.insertBook(metadata: makeMetadata(), formatType: .epub,
                             originalFileName: "dispossessed.epub", byteSize: 1234,
                             contentHash: "abc123", bookID: bookID, formatID: formatID)

        let book = try XCTUnwrap(store.fetchBook(bookID))
        XCTAssertEqual(book.title, "The Dispossessed")
        XCTAssertEqual(book.titleSort, "Dispossessed, The")
        XCTAssertGreaterThan(book.applySeq, 0)

        let formats = try store.fetchFormats(bookID: bookID)
        XCTAssertEqual(formats.map(\.contentHash), ["abc123"])
        XCTAssertEqual(try store.fetchAuthors(bookID: bookID), ["Ursula K. Le Guin"])
    }

    func testContributorsAreDeduplicatedAcrossBooks() throws {
        let dbm = try DatabaseManager.inMemory()
        let store = LibraryStore(dbm: dbm)
        try store.insertBook(metadata: makeMetadata(), formatType: .epub, originalFileName: "a.epub",
                             byteSize: 1, contentHash: "h1", bookID: UUID(), formatID: UUID())
        try store.insertBook(metadata: makeMetadata(), formatType: .epub, originalFileName: "b.epub",
                             byteSize: 2, contentHash: "h2", bookID: UUID(), formatID: UUID())
        let count = try dbm.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM contributor")!
        }
        XCTAssertEqual(count, 1)
    }
}
