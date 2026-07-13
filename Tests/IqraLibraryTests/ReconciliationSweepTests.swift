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

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
        XCTAssertEqual(report.stagingDeleted, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.stagingDir.path).count, 0)
    }

    func testAdoptsOrphanFolderFromSidecar() throws {
        let epub = try Fixtures.makeEPUB(title: "Orphan Book", author: "A. Author",
                                         isbn: "9990000000001", dir: dir)
        pipeline.failpoint = .afterRename
        XCTAssertThrowsError(try pipeline.importFile(at: epub))
        XCTAssertNil(try dbm.writer.read { try BookRecord.fetchOne($0) })

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
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
        XCTAssertEqual(try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches).orphansAdopted, 0)
    }

    func testMarksMissingFormats() throws {
        let epub = try Fixtures.makeEPUB(title: "Vanishing", author: "A", isbn: nil, dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else { return XCTFail() }
        let format = try XCTUnwrap(store.fetchFormats(bookID: bookID).first)
        try FileManager.default.removeItem(
            at: paths.formatFile(bookID: bookID, formatID: UUID(uuidString: format.id)!, type: .epub))

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
        XCTAssertEqual(report.formatsMarkedMissing, 1)
        let row = try dbm.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT present, missing FROM format_local WHERE formatId = ?",
                             arguments: [format.id])!
        }
        XCTAssertEqual(row["present"] as Bool, false)
        XCTAssertEqual(row["missing"] as Bool, true)
    }

    // MARK: - Finding 1: per-item failure isolation

    func testIsolatesFailingOrphanAndContinuesSweep() throws {
        // A book whose binary will vanish -- used below to prove phase 3 still runs even
        // though phase 2 hits a failure partway through.
        let vanishing = try Fixtures.makeEPUB(title: "Vanishing", author: "A", isbn: nil, dir: dir)
        guard case .imported = try pipeline.importFile(at: vanishing) else { return XCTFail() }

        // A first orphan, created then adopted normally so its bookID becomes "taken".
        let beforeOrphan1 = try FileManager.default.contentsOfDirectory(
            at: paths.booksDir, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        let orphan1 = try Fixtures.makeEPUB(title: "Orphan1", author: "A", isbn: nil, dir: dir)
        pipeline.failpoint = .afterRename
        XCTAssertThrowsError(try pipeline.importFile(at: orphan1))
        pipeline.failpoint = nil
        let afterOrphan1 = try FileManager.default.contentsOfDirectory(
            at: paths.booksDir, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        let orphan1Name = try XCTUnwrap(Set(afterOrphan1).subtracting(beforeOrphan1).first)
        XCTAssertEqual(try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches).orphansAdopted, 1)

        // Now that orphan1's bookID is a real row, copy its sidecar into a *new* folder (a
        // different name, so it still looks orphaned) -- adopting it will try to insert a
        // book with a bookID that already exists, so store.insertBook must throw.
        let orphan1Folder = paths.booksDir.appendingPathComponent(orphan1Name, isDirectory: true)
        let badFolder = paths.booksDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: badFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: orphan1Folder.appendingPathComponent("metadata.json"),
            to: badFolder.appendingPathComponent("metadata.json"))

        // Only now make the vanishing book's binary disappear, so the upcoming sweep (the one
        // under test) is the one that discovers it.
        let vanishingBookID = try XCTUnwrap(try dbm.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM book WHERE title = 'Vanishing'")
        })
        let vanishingFormatID = try XCTUnwrap(try dbm.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM format WHERE bookId = ?", arguments: [vanishingBookID])
        })
        try FileManager.default.removeItem(
            at: paths.formatFile(bookID: UUID(uuidString: vanishingBookID)!,
                                 formatID: UUID(uuidString: vanishingFormatID)!, type: .epub))

        // A second, good orphan that must still be adopted despite the bad folder failing.
        let orphan2 = try Fixtures.makeEPUB(title: "Orphan2", author: "A", isbn: nil, dir: dir)
        pipeline.failpoint = .afterRename
        XCTAssertThrowsError(try pipeline.importFile(at: orphan2))
        pipeline.failpoint = nil

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
        XCTAssertEqual(report.orphansAdopted, 1, "only the good orphan (Orphan2)")
        XCTAssertEqual(report.failures, 1, "the colliding folder must be counted as a failure, not thrown")
        XCTAssertEqual(report.formatsMarkedMissing, 1, "phase 3 still ran after the phase-2 failure")

        let titles = try dbm.writer.read { db in try String.fetchAll(db, sql: "SELECT title FROM book") }
        XCTAssertTrue(titles.contains("Orphan2"))
    }

    // MARK: - Finding 2: multi-format sidecar adoption

    func testAdoptsAllFormatsFromMultiFormatSidecar() throws {
        let bookID = UUID()
        let epubID = UUID()
        let pdfID = UUID()
        let folder = paths.bookDir(bookID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let epubData = Data("epub-bytes".utf8)
        let pdfData = Data("pdf-bytes".utf8)
        try epubData.write(to: folder.appendingPathComponent("\(epubID.uuidString).epub"))
        try pdfData.write(to: folder.appendingPathComponent("\(pdfID.uuidString).pdf"))

        let metadata = ExtractedMetadata(
            title: "Multi Format", titleSort: "Multi Format", language: "en", publisher: nil,
            bookDescription: nil,
            contributors: [Contributor(name: "A. Author", sortName: "Author, A.", role: .author)],
            identifiers: [])
        let sidecar = Sidecar(bookID: bookID, metadata: metadata, formats: [
            .init(formatID: epubID, formatType: .epub, originalFileName: "book.epub",
                 byteSize: Int64(epubData.count), contentHash: "epub-hash"),
            .init(formatID: pdfID, formatType: .pdf, originalFileName: "book.pdf",
                 byteSize: Int64(pdfData.count), contentHash: "pdf-hash"),
        ], applySeq: 0)
        try Sidecar.write(sidecar, to: folder.appendingPathComponent("metadata.json"))

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
        XCTAssertEqual(report.orphansAdopted, 1)
        XCTAssertEqual(report.failures, 0)

        let formats = try store.fetchFormats(bookID: bookID)
        XCTAssertEqual(formats.count, 2)
        for format in formats {
            let present = try dbm.writer.read { db in
                try Bool.fetchOne(db, sql: "SELECT present FROM format_local WHERE formatId = ?",
                                  arguments: [format.id])!
            }
            XCTAssertTrue(present, "format \(format.formatType) should be present")
        }
    }

    func testAdoptsMultiFormatSidecarMarksMissingWhenExtraFileAbsent() throws {
        let bookID = UUID()
        let epubID = UUID()
        let pdfID = UUID() // no file written for this one
        let folder = paths.bookDir(bookID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let epubData = Data("epub-bytes".utf8)
        try epubData.write(to: folder.appendingPathComponent("\(epubID.uuidString).epub"))

        let metadata = ExtractedMetadata(title: "Missing Extra", titleSort: "Missing Extra",
                                         language: "en", publisher: nil, bookDescription: nil,
                                         contributors: [], identifiers: [])
        let sidecar = Sidecar(bookID: bookID, metadata: metadata, formats: [
            .init(formatID: epubID, formatType: .epub, originalFileName: "book.epub",
                 byteSize: Int64(epubData.count), contentHash: "epub-hash"),
            .init(formatID: pdfID, formatType: .pdf, originalFileName: "book.pdf",
                 byteSize: 0, contentHash: "pdf-hash"),
        ], applySeq: 0)
        try Sidecar.write(sidecar, to: folder.appendingPathComponent("metadata.json"))

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
        XCTAssertEqual(report.orphansAdopted, 1)

        let row = try dbm.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT present, missing FROM format_local WHERE formatId = ?",
                             arguments: [pdfID.uuidString])!
        }
        XCTAssertEqual(row["present"] as Bool, false)
        XCTAssertEqual(row["missing"] as Bool, true)
    }

    func testStaleImportingRowsAreMarkedFailedBySweep() throws {
        // simulate a crash mid-import: row left at 'importing'
        let epub = try Fixtures.makeEPUB(title: "Stale", author: "A", isbn: nil, dir: dir)
        pipeline.failpoint = .afterStaging
        XCTAssertThrowsError(try pipeline.importFile(at: epub))
        let importing = try dbm.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM import_item WHERE status = 'importing'")!
        }
        XCTAssertEqual(importing, 1)

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
        XCTAssertEqual(report.staleImportsFailed, 1)
        let row = try dbm.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT status, message FROM import_item")!
        }
        XCTAssertEqual(row["status"] as String, "failed")
        XCTAssertNotNil(row["message"] as String?)
    }

    func testSweepAdoptsSidecarFormatsForKnownBooks() throws {
        // attach crash after the sidecar write: sidecar lists a format the DB doesn't know
        let first = try Fixtures.makeEPUB(title: "Known", author: "A", isbn: "9991112223334", dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: first) else { return XCTFail() }
        let second = try Fixtures.makeEPUB(title: "Known Two", author: "A", isbn: "9991112223334", dir: dir)
        pipeline.failpoint = .afterAttachSidecar
        XCTAssertThrowsError(try pipeline.importFile(at: second, resolution: .attach(toBook: bookID)))
        pipeline.failpoint = nil
        XCTAssertEqual(try store.fetchFormats(bookID: bookID).count, 1) // DB behind sidecar

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
        XCTAssertEqual(report.formatsAdoptedForKnownBooks, 1)
        let formats = try store.fetchFormats(bookID: bookID)
        XCTAssertEqual(formats.count, 2)
        // adopted format is present (its file was written before the sidecar)
        let adopted = formats.first { $0.originalFileName == second.lastPathComponent }
        XCTAssertNotNil(adopted)
        // idempotent
        XCTAssertEqual(try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
            .formatsAdoptedForKnownBooks, 0)
    }

    func testSweepDeletesStalePartialFiles() throws {
        let epub = try Fixtures.makeEPUB(title: "P", author: "A", isbn: nil, dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else { return XCTFail() }
        let stale = paths.bookDir(bookID).appendingPathComponent("\(UUID().uuidString).epub.partial")
        try Data("half".utf8).write(to: stale)

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
        XCTAssertEqual(report.partialsDeleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testOrphanAdoptionSkipsDuplicateContentHash() throws {
        // book already in the DB; an orphan folder re-describes the same bytes under a new bookID
        let epub = try Fixtures.makeEPUB(title: "Dup", author: "A", isbn: nil, dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else { return XCTFail() }
        let format = try XCTUnwrap(store.fetchFormats(bookID: bookID).first)
        let orphanID = UUID()
        let orphanDir = paths.bookDir(orphanID)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let sidecar = Sidecar(bookID: orphanID,
                              metadata: ExtractedMetadata(title: "Dup", titleSort: "Dup", language: "en",
                                                          publisher: nil, bookDescription: nil,
                                                          contributors: [], identifiers: []),
                              formats: [.init(formatID: UUID(), formatType: .epub,
                                              originalFileName: "dup.epub", byteSize: format.byteSize,
                                              contentHash: format.contentHash)],
                              applySeq: 0)
        try Sidecar.write(sidecar, to: orphanDir.appendingPathComponent("metadata.json"))

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
        XCTAssertEqual(report.orphansAdopted, 0)
        XCTAssertEqual(report.orphansSkippedAsDuplicates, 1)
        XCTAssertEqual(try dbm.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM book")! }, 1)
    }

    func testAdoptedOrphanGetsThumbnailsBackfilled() throws {
        let epub = try Fixtures.makeEPUB(title: "Thumb", author: "A", isbn: nil,
                                         coverJPEG: Fixtures.tinyJPEG(), dir: dir)
        pipeline.failpoint = .afterRename  // crash BEFORE ThumbnailPipeline ran
        XCTAssertThrowsError(try pipeline.importFile(at: epub))
        pipeline.failpoint = nil

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
        XCTAssertEqual(report.orphansAdopted, 1)
        let bookID = try XCTUnwrap(try dbm.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM book")
        }).flatMap(UUID.init(uuidString:)) ?? UUID()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: caches.thumbnail(bookID: bookID, size: .grid).path))
    }
}
