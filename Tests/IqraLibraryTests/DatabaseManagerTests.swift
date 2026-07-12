import XCTest
import GRDB
@testable import IqraLibrary

final class DatabaseManagerTests: XCTestCase {
    func testMigrationCreatesFullSchema() throws {
        let dbm = try DatabaseManager.inMemory()
        try dbm.writer.read { db in
            for table in ["book", "contributor", "book_contributor", "series", "tag", "book_tag",
                          "identifier", "format", "format_local", "collection", "collection_book",
                          "field_lock", "reading_state", "annotation", "import_item", "apply_sequence"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
            // FTS table lives in the attached "fts" schema
            let n = try Int.fetchOne(db, sql:
                "SELECT count(*) FROM fts.sqlite_master WHERE name = 'book_fts'")
            XCTAssertEqual(n, 1)
        }
    }

    func testApplySequenceIsMonotonic() throws {
        let dbm = try DatabaseManager.inMemory()
        let (a, b) = try dbm.writer.write { db in
            (try dbm.nextApplySequence(db), try dbm.nextApplySequence(db))
        }
        XCTAssertEqual(b, a + 1)
    }
}
