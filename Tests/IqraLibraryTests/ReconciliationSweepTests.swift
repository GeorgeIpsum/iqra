import XCTest
import IqraCore
import GRDB
@testable import IqraLibrary

final class ReconciliationSweepTests: XCTestCase {
    var dir: URL!
    var dbm: DatabaseManager!
    var store: LibraryStore!
    var paths: LibraryPaths!
    var caches: LibraryPaths.Caches!
    var pipeline: ImportPipeline!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbm = try DatabaseManager.inMemory()
        store = LibraryStore(dbm: dbm)
        paths = LibraryPaths(root: dir.appendingPathComponent("lib"))
        caches = LibraryPaths.Caches(root: dir.appendingPathComponent("caches"))
        pipeline = ImportPipeline(store: store, dbm: dbm, paths: paths, caches: caches)
    }

    func testCleansStagingLeftovers() throws {
        let epub = try Fixtures.makeEPUB(title: "Crash1", author: "A", isbn: nil, dir: dir)
        pipeline.failpoint = .afterStaging
        XCTAssertThrowsError(try pipeline.importFile(at: epub))

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm)
        XCTAssertEqual(report.stagingDeleted, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.stagingDir.path).count, 0)
    }

    func testAdoptsOrphanFolderFromSidecar() throws {
        let epub = try Fixtures.makeEPUB(title: "Orphan Book", author: "A. Author",
                                         isbn: "9990000000001", dir: dir)
        pipeline.failpoint = .afterRename
        XCTAssertThrowsError(try pipeline.importFile(at: epub))
        XCTAssertNil(try dbm.writer.read { try BookRecord.fetchOne($0) })

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm)
        XCTAssertEqual(report.orphansAdopted, 1)
        let book = try XCTUnwrap(try dbm.writer.read { try BookRecord.fetchOne($0) })
        XCTAssertEqual(book.title, "Orphan Book")
        // adopted format is present locally (the file is in the folder)
        let format = try XCTUnwrap(store.fetchFormats(bookID: UUID(uuidString: book.id)!).first)
        let present = try dbm.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT present FROM format_local WHERE formatId = ?",
                              arguments: [format.id])!
        }
        XCTAssertTrue(present)
        // idempotent: second sweep adopts nothing
        XCTAssertEqual(try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm).orphansAdopted, 0)
    }

    func testMarksMissingFormats() throws {
        let epub = try Fixtures.makeEPUB(title: "Vanishing", author: "A", isbn: nil, dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else { return XCTFail() }
        let format = try XCTUnwrap(store.fetchFormats(bookID: bookID).first)
        try FileManager.default.removeItem(
            at: paths.formatFile(bookID: bookID, formatID: UUID(uuidString: format.id)!, type: .epub))

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm)
        XCTAssertEqual(report.formatsMarkedMissing, 1)
        let row = try dbm.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT present, missing FROM format_local WHERE formatId = ?",
                             arguments: [format.id])!
        }
        XCTAssertEqual(row["present"] as Bool, false)
        XCTAssertEqual(row["missing"] as Bool, true)
    }
}
