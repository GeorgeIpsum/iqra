import XCTest
import IqraCore
import GRDB
@testable import IqraLibrary

final class ImportPipelineTests: XCTestCase {
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

    func importCount(status: String) throws -> Int {
        try dbm.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM import_item WHERE status = ?",
                             arguments: [status])!
        }
    }

    func testHappyPathEPUB() throws {
        let epub = try Fixtures.makeEPUB(title: "The Dispossessed", author: "Ursula K. Le Guin",
                                         isbn: "9780060512750", coverJPEG: Fixtures.tinyJPEG(), dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else {
            return XCTFail("expected imported")
        }
        // DB row exists with metadata
        let book = try XCTUnwrap(store.fetchBook(bookID))
        XCTAssertEqual(book.title, "The Dispossessed")
        // managed folder layout: <formatUUID>.epub + metadata.json + cover.jpg
        let format = try XCTUnwrap(store.fetchFormats(bookID: bookID).first)
        let formatURL = paths.formatFile(bookID: bookID, formatID: UUID(uuidString: format.id)!, type: .epub)
        XCTAssertTrue(FileManager.default.fileExists(atPath: formatURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.metadataSidecar(bookID: bookID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cover(bookID: bookID).path))
        // sidecar agrees with the DB
        let sidecar = try Sidecar.read(from: paths.metadataSidecar(bookID: bookID))
        XCTAssertEqual(sidecar.bookID, bookID)
        XCTAssertEqual(sidecar.formats.first?.contentHash, format.contentHash)
        // no staging leftovers; import_item done
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stagingBookDir(bookID).path))
        XCTAssertEqual(try importCount(status: "done"), 1)
    }

    func testHappyPathPDF() throws {
        let pdf = try Fixtures.makePDF(title: "Design Patterns", author: "Gamma", dir: dir)
        guard case .imported = try pipeline.importFile(at: pdf) else { return XCTFail() }
        XCTAssertEqual(try importCount(status: "done"), 1)
    }

    func testDRMEPUBIsQuarantined() throws {
        let epub = try Fixtures.makeEPUB(title: "Locked", author: "X", isbn: nil, encrypted: true, dir: dir)
        XCTAssertEqual(try pipeline.importFile(at: epub), .quarantined(.drmProtected))
        XCTAssertEqual(try importCount(status: "quarantined"), 1)
        XCTAssertNil(try dbm.writer.read { try BookRecord.fetchOne($0) }) // nothing imported
    }

    func testUnsupportedFormatIsQuarantinedInM1() throws {
        let junk = dir.appendingPathComponent("junk.xyz")
        try Data("not a book".utf8).write(to: junk)
        XCTAssertEqual(try pipeline.importFile(at: junk), .quarantined(.unsupportedFormat))
    }

    func testExactDuplicateIsSkipped() throws {
        let epub = try Fixtures.makeEPUB(title: "Dup", author: "A", isbn: nil, dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else { return XCTFail() }
        let format = try XCTUnwrap(store.fetchFormats(bookID: bookID).first)
        XCTAssertEqual(try pipeline.importFile(at: epub),
                       .skippedExactDuplicate(formatID: UUID(uuidString: format.id)!))
        XCTAssertEqual(try dbm.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM book")! }, 1)
    }

    func testHashMatchWithMissingBinaryHydrates() throws {
        let epub = try Fixtures.makeEPUB(title: "Hyd", author: "A", isbn: nil, dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else { return XCTFail() }
        let format = try XCTUnwrap(store.fetchFormats(bookID: bookID).first)
        let formatID = UUID(uuidString: format.id)!
        // simulate lost binary (e.g. synced record without local file)
        let fileURL = paths.formatFile(bookID: bookID, formatID: formatID, type: .epub)
        try FileManager.default.removeItem(at: fileURL)
        try dbm.writer.write { db in
            try db.execute(sql: "UPDATE format_local SET present = 0, missing = 1 WHERE formatId = ?",
                           arguments: [format.id])
        }
        XCTAssertEqual(try pipeline.importFile(at: epub), .hydrated(formatID: formatID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let present = try dbm.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT present FROM format_local WHERE formatId = ?",
                              arguments: [format.id])!
        }
        XCTAssertTrue(present)
    }

    func testHashMatchIgnoresSoftDeletedBook() throws {
        let epub = try Fixtures.makeEPUB(title: "Tombstoned", author: "A", isbn: nil, dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else { return XCTFail() }
        try dbm.writer.write { db in
            try db.execute(sql: "UPDATE book SET deleted = 1 WHERE id = ?", arguments: [bookID.uuidString])
        }
        // re-importing the identical bytes must not skip/hydrate against a tombstoned book —
        // it should import as a brand-new book, just like the identifier-match branch already does.
        guard case let .imported(newBookID) = try pipeline.importFile(at: epub) else {
            return XCTFail("expected a fresh import, not skip/hydrate against a deleted book")
        }
        XCTAssertNotEqual(newBookID, bookID)
    }

    func testIdentifierMatchAsksThenAttaches() throws {
        // same ISBN, different bytes (different title string → different hash)
        let first = try Fixtures.makeEPUB(title: "Edition One", author: "A", isbn: "9780060512750", dir: dir)
        let second = try Fixtures.makeEPUB(title: "Edition Two", author: "A", isbn: "9780060512750", dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: first) else { return XCTFail() }
        // default: never silent
        XCTAssertEqual(try pipeline.importFile(at: second), .needsUserDecision(existingBookID: bookID))
        XCTAssertEqual(try dbm.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM book")! }, 1)
        // user chose the default action: attach as a format of the existing book
        guard case let .attached(attachedBookID, formatID) =
            try pipeline.importFile(at: second, resolution: .attach(toBook: bookID)) else {
            return XCTFail("expected attached")
        }
        XCTAssertEqual(attachedBookID, bookID)
        XCTAssertEqual(try store.fetchFormats(bookID: bookID).count, 2)
        let fileURL = paths.formatFile(bookID: bookID, formatID: formatID, type: .epub)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        // the "pending" row written by the .ask decision must not be orphaned: resolving
        // the decision should reuse its id rather than mint a fresh one, so it lands in a
        // terminal status instead of being stuck at "pending" forever.
        XCTAssertEqual(try importCount(status: "pending"), 0)
        let terminalRows = try dbm.writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM import_item WHERE sourceDisplayPath = ? AND status = 'done'
                """, arguments: [second.path])!
        }
        XCTAssertEqual(terminalRows, 1)
    }

    func testCrashAfterStagingLeavesNoDBRow() throws {
        let epub = try Fixtures.makeEPUB(title: "Crash1", author: "A", isbn: nil, dir: dir)
        pipeline.failpoint = .afterStaging
        XCTAssertThrowsError(try pipeline.importFile(at: epub))
        XCTAssertNil(try dbm.writer.read { try BookRecord.fetchOne($0) })
        // staging leftover exists for the sweep to clean
        let staged = try FileManager.default.contentsOfDirectory(atPath: paths.stagingDir.path)
        XCTAssertEqual(staged.count, 1)
    }

    func testCrashAfterRenameLeavesAdoptableOrphan() throws {
        let epub = try Fixtures.makeEPUB(title: "Crash2", author: "A", isbn: nil, dir: dir)
        pipeline.failpoint = .afterRename
        XCTAssertThrowsError(try pipeline.importFile(at: epub))
        XCTAssertNil(try dbm.writer.read { try BookRecord.fetchOne($0) })
        // a fully-formed book folder exists (self-describing via sidecar), no DB row
        let folders = try FileManager.default.contentsOfDirectory(atPath: paths.booksDir.path)
            .filter { $0 != ".staging" }
        XCTAssertEqual(folders.count, 1)
        let sidecarURL = paths.booksDir.appendingPathComponent(folders[0]).appendingPathComponent("metadata.json")
        XCTAssertNoThrow(try Sidecar.read(from: sidecarURL))
    }

    func testRealFailureMarksImportItemFailed() throws {
        let epub = try Fixtures.makeEPUB(title: "RealFailure", author: "A", isbn: nil, dir: dir)
        // Deterministic real-error injection (not a failpoint): pre-create the ".staging"
        // path segment as a plain file instead of a directory. mkdir-with-intermediates
        // then fails with a genuine "Not a directory" filesystem error — reproducible
        // regardless of user/root permissions, unlike a chmod-based trick.
        try FileManager.default.createDirectory(at: paths.booksDir, withIntermediateDirectories: true)
        try Data().write(to: paths.stagingDir)
        XCTAssertThrowsError(try pipeline.importFile(at: epub))
        let row = try dbm.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT status, message FROM import_item WHERE sourceDisplayPath = ?
                """, arguments: [epub.path])
        }
        let unwrapped = try XCTUnwrap(row)
        XCTAssertEqual(unwrapped["status"] as String, "failed")
        XCTAssertNotNil(unwrapped["message"] as String?)
    }
}
