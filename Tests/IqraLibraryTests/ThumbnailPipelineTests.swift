import XCTest
@testable import IqraLibrary

final class ThumbnailPipelineTests: XCTestCase {
    func testWritesCoverAndTwoThumbnailSizes() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = LibraryPaths(root: tmp.appendingPathComponent("lib"))
        let caches = LibraryPaths.Caches(root: tmp.appendingPathComponent("caches"))
        let bookID = UUID()
        let bookDir = paths.bookDir(bookID)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)

        try ThumbnailPipeline.process(coverData: Fixtures.tinyJPEG(), bookDir: bookDir,
                                      bookID: bookID, caches: caches)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cover(bookID: bookID).path))
        for size in ThumbnailSize.allCases {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: caches.thumbnail(bookID: bookID, size: size).path), "missing \(size)")
        }
    }

    func testNilCoverIsNoOp() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let caches = LibraryPaths.Caches(root: tmp.appendingPathComponent("caches"))
        try ThumbnailPipeline.process(coverData: nil, bookDir: tmp, bookID: UUID(), caches: caches)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("cover.jpg").path))
    }
}
