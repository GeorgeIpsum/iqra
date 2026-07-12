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
