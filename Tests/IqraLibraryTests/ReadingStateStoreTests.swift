import XCTest
import IqraCore
import GRDB
@testable import IqraLibrary

final class ReadingStateStoreTests: XCTestCase {
    var dbm: DatabaseManager!
    var store: LibraryStore!
    var reading: ReadingStateStore!
    var bookID: UUID!
    var formatID: UUID!

    override func setUpWithError() throws {
        dbm = try DatabaseManager.inMemory()
        store = LibraryStore(dbm: dbm)
        reading = ReadingStateStore(dbm: dbm)
        bookID = UUID(); formatID = UUID()
        let meta = ExtractedMetadata(title: "T", titleSort: "T", language: "en", publisher: nil,
                                     bookDescription: nil, contributors: [], identifiers: [])
        try store.insertBook(metadata: meta, formatType: .epub, originalFileName: "t.epub",
                             byteSize: 1, contentHash: "h", bookID: bookID, formatID: formatID)
    }

    func testSaveAndReadLocatorRoundTrip() throws {
        let json = Data(#"{"spineIndex":3,"totalProgression":0.25}"#.utf8)
        try reading.saveLocator(json: json, totalProgression: 0.25, bookID: bookID, formatID: formatID)
        XCTAssertEqual(try reading.locatorJSON(bookID: bookID, formatID: formatID), json)
        XCTAssertNil(try reading.locatorJSON(bookID: UUID(), formatID: UUID()))
    }

    func testHighWaterMarkOnlyGrows() throws {
        let j = Data("{}".utf8)
        XCTAssertEqual(try reading.saveLocator(json: j, totalProgression: 0.5,
                                               bookID: bookID, formatID: formatID), 0.5)
        // going BACK in the book must not lower the mark
        XCTAssertEqual(try reading.saveLocator(json: j, totalProgression: 0.2,
                                               bookID: bookID, formatID: formatID), 0.5)
        XCTAssertEqual(try reading.highWaterMark(bookID: bookID, formatID: formatID), 0.5)
        // but the CURRENT locator does move back
        let back = Data(#"{"totalProgression":0.2}"#.utf8)
        try reading.saveLocator(json: back, totalProgression: 0.2, bookID: bookID, formatID: formatID)
        XCTAssertEqual(try reading.locatorJSON(bookID: bookID, formatID: formatID), back)
    }

    func testSaveStampsApplySequence() throws {
        try reading.saveLocator(json: Data("{}".utf8), totalProgression: 0.1,
                                bookID: bookID, formatID: formatID)
        let seq1 = try dbm.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT applySeq FROM reading_state")!
        }
        try reading.saveLocator(json: Data("{}".utf8), totalProgression: 0.2,
                                bookID: bookID, formatID: formatID)
        let seq2 = try dbm.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT applySeq FROM reading_state")!
        }
        XCTAssertGreaterThan(seq2, seq1)
    }

    func testOpenableFormatAndMarkOpened() throws {
        let format = try XCTUnwrap(try store.openableFormat(bookID: bookID))
        XCTAssertEqual(format.id, formatID.uuidString)
        // a missing binary is not openable
        try dbm.writer.write { db in
            try db.execute(sql: "UPDATE format_local SET present = 0, missing = 1 WHERE formatId = ?",
                           arguments: [formatID.uuidString])
        }
        XCTAssertNil(try store.openableFormat(bookID: bookID))

        try store.markOpened(bookID: bookID)
        let opened = try dbm.writer.read { db in
            try Date.fetchOne(db, sql: "SELECT lastOpenedAt FROM book WHERE id = ?",
                              arguments: [bookID.uuidString])
        }
        XCTAssertNotNil(opened)
    }
}
