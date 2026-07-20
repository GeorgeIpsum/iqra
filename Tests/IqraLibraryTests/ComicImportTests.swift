import XCTest
import IqraCore
import GRDB
import ZIPFoundation
@testable import IqraLibrary

final class ComicImportTests: XCTestCase {
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

    func testImportsCBZAsBookWithCover() throws {
        let cbz = try Fixtures.makeCBZ(comicInfoTitle: "Watchmen #1",
                                       pageImages: [Fixtures.tinyJPEG()], dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: cbz) else {
            return XCTFail("expected imported")
        }
        let book = try XCTUnwrap(store.fetchBook(bookID))
        XCTAssertEqual(book.title, "Watchmen #1")

        let format = try XCTUnwrap(store.fetchFormats(bookID: bookID).first)
        XCTAssertEqual(format.formatType, "cbz")
        let formatURL = paths.formatFile(bookID: bookID, formatID: UUID(uuidString: format.id)!, type: .cbz)
        XCTAssertTrue(FileManager.default.fileExists(atPath: formatURL.path))
        // cover.jpg written from the first sorted page image (eager thumbnail at import, spec)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cover(bookID: bookID).path))
        // full page extraction is NOT done at import — lazy at first open (Task 8) — so no
        // comic pages cache should exist yet.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: caches.comicPagesDir(formatID: UUID(uuidString: format.id)!).path))
        XCTAssertEqual(try importCount(status: "done"), 1)
    }

    func testCBZWithoutComicInfoFallsBackToFileName() throws {
        let cbz = try Fixtures.makeCBZ(comicInfoTitle: nil, pageImages: [Fixtures.tinyJPEG()], dir: dir)
        let expectedTitle = cbz.deletingPathExtension().lastPathComponent
        guard case let .imported(bookID) = try pipeline.importFile(at: cbz) else {
            return XCTFail("expected imported")
        }
        let book = try XCTUnwrap(store.fetchBook(bookID))
        XCTAssertEqual(book.title, expectedTitle)
    }

    func testCorruptCBZIsQuarantined() throws {
        // a .cbz (zip magic, no epub mimetype) with no image entries at all
        let url = dir.appendingPathComponent("empty.cbz")
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        try archive.addEntry(with: "ComicInfo.xml", type: .file, uncompressedSize: Int64(12),
                             provider: { p, s in Data("<ComicInfo/>".utf8).subdata(in: Int(p)..<Int(p) + s) })
        XCTAssertEqual(try pipeline.importFile(at: url), .quarantined(.corruptContainer))
        XCTAssertEqual(try importCount(status: "quarantined"), 1)
    }

    func testCBRStillQuarantined() throws {
        let url = dir.appendingPathComponent("comic.cbr")
        try Data("Rar!\u{05}\u{07}\u{00}rest-of-file".utf8).write(to: url)
        XCTAssertEqual(try pipeline.importFile(at: url), .quarantined(.unsupportedFormat))
        XCTAssertEqual(try importCount(status: "quarantined"), 1)
        XCTAssertNil(try dbm.writer.read { try BookRecord.fetchOne($0) })
    }
}
