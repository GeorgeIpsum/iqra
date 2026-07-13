import XCTest
import GRDB
@testable import IqraLibrary

final class AnnotationStoreTests: XCTestCase {
    var dbm: DatabaseManager!
    var store: LibraryStore!
    var annotations: AnnotationStore!
    var bookID: UUID!
    var formatID: UUID!

    override func setUpWithError() throws {
        dbm = try DatabaseManager.inMemory()
        store = LibraryStore(dbm: dbm)
        annotations = AnnotationStore(dbm: dbm)
        bookID = UUID(); formatID = UUID()
        try store.insertBook(
            metadata: .init(title: "T", titleSort: "T", language: "en", publisher: nil,
                            bookDescription: nil, contributors: [], identifiers: []),
            formatType: .epub, originalFileName: "t.epub", byteSize: 1, contentHash: "h",
            bookID: bookID, formatID: formatID)
    }

    /// A minimal locator JSON with the two fields the ordering relies on.
    func locator(spine: Int, progress: Double) -> Data {
        Data(#"{"spineIndex":\#(spine),"totalProgression":\#(progress),"cfi":"epubcfi(/6/\#(spine))"}"#.utf8)
    }

    func testUpsertInsertsThenUpdatesPreservingCreatedAt() throws {
        let id = UUID()
        try annotations.upsert(id: id, bookID: bookID, formatID: formatID, kind: "highlight",
                               locatorJSON: locator(spine: 2, progress: 0.2), color: "yellow", noteText: nil)
        let first = try XCTUnwrap(annotations.annotation(id: id))
        XCTAssertEqual(first.color, "yellow")
        XCTAssertNil(first.noteText)
        let created = first.createdAt

        try annotations.upsert(id: id, bookID: bookID, formatID: formatID, kind: "note",
                               locatorJSON: locator(spine: 2, progress: 0.2), color: "green",
                               noteText: "a thought")
        let updated = try XCTUnwrap(annotations.annotation(id: id))
        XCTAssertEqual(updated.color, "green")
        XCTAssertEqual(updated.noteText, "a thought")
        XCTAssertEqual(updated.createdAt, created)                 // preserved
        XCTAssertGreaterThanOrEqual(updated.modifiedAt, created)   // bumped
    }

    func testDeleteTombstonesAndHidesFromList() throws {
        let id = UUID()
        try annotations.upsert(id: id, bookID: bookID, formatID: formatID, kind: "highlight",
                               locatorJSON: locator(spine: 1, progress: 0.1), color: "blue", noteText: nil)
        try annotations.delete(id: id)
        XCTAssertEqual(try annotations.annotations(bookID: bookID, formatID: formatID).count, 0)
        // the tombstone row itself persists (permanent)
        let row = try XCTUnwrap(annotations.annotation(id: id))
        XCTAssertTrue(row.deleted)
    }

    func testListIsOrderedBySpineThenProgress() throws {
        // insert out of order
        for (spine, prog) in [(3, 0.5), (1, 0.9), (1, 0.2), (2, 0.4)] {
            try annotations.upsert(id: UUID(), bookID: bookID, formatID: formatID, kind: "highlight",
                                   locatorJSON: locator(spine: spine, progress: prog),
                                   color: "yellow", noteText: nil)
        }
        let ordered = try annotations.annotations(bookID: bookID, formatID: formatID)
        let keys = ordered.map { rec -> String in
            let obj = try! JSONSerialization.jsonObject(with: Data(rec.locator.utf8)) as! [String: Any]
            return "\(obj["spineIndex"]!)-\(obj["totalProgression"]!)"
        }
        XCTAssertEqual(keys, ["1-0.2", "1-0.9", "2-0.4", "3-0.5"])
    }

    func testUpsertStampsIncreasingApplySequence() throws {
        let a = UUID(), b = UUID()
        try annotations.upsert(id: a, bookID: bookID, formatID: formatID, kind: "bookmark",
                               locatorJSON: locator(spine: 1, progress: 0.1), color: nil, noteText: nil)
        try annotations.upsert(id: b, bookID: bookID, formatID: formatID, kind: "bookmark",
                               locatorJSON: locator(spine: 1, progress: 0.3), color: nil, noteText: nil)
        let seqA = try XCTUnwrap(annotations.annotation(id: a)).applySeq
        let seqB = try XCTUnwrap(annotations.annotation(id: b)).applySeq
        XCTAssertGreaterThan(seqB, seqA)
    }

    func testObservationFiresOnInsert() throws {
        let exp = expectation(description: "observed"); exp.expectedFulfillmentCount = 2
        var seen: [[AnnotationRecord]] = []
        let cancellable = annotations.observeAnnotations(bookID: bookID, formatID: formatID).start(
            in: dbm.writer, onError: { XCTFail("\($0)") }, onChange: { seen.append($0); exp.fulfill() })
        try annotations.upsert(id: UUID(), bookID: bookID, formatID: formatID, kind: "highlight",
                               locatorJSON: locator(spine: 1, progress: 0.1), color: "pink", noteText: nil)
        wait(for: [exp], timeout: 5); cancellable.cancel()
        XCTAssertEqual(seen.last?.count, 1)
    }
}
