import XCTest
import ImageIO
@testable import IqraLibrary

final class ThumbnailPipelineTests: XCTestCase {
    private func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    func testWritesCoverAndTwoThumbnailSizes() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = LibraryPaths(root: tmp.appendingPathComponent("lib"))
        let caches = LibraryPaths.Caches(root: tmp.appendingPathComponent("caches"))
        let bookID = UUID()
        try FileManager.default.createDirectory(at: paths.bookDir(bookID), withIntermediateDirectories: true)

        let result = try ThumbnailPipeline.process(coverData: Fixtures.largeJPEG(), bookID: bookID,
                                                    paths: paths, caches: caches)

        XCTAssertEqual(result, .written)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cover(bookID: bookID).path))
        for size in ThumbnailSize.allCases {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: caches.thumbnail(bookID: bookID, size: size).path), "missing \(size)")
        }

        let gridSize = try XCTUnwrap(pixelSize(of: caches.thumbnail(bookID: bookID, size: .grid)))
        XCTAssertLessThanOrEqual(gridSize.width, 300)
        XCTAssertLessThanOrEqual(gridSize.height, 300)

        let listSize = try XCTUnwrap(pixelSize(of: caches.thumbnail(bookID: bookID, size: .list)))
        XCTAssertLessThanOrEqual(listSize.width, 90)
        XCTAssertLessThanOrEqual(listSize.height, 90)
    }

    func testNilCoverIsNoOp() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = LibraryPaths(root: tmp.appendingPathComponent("lib"))
        let caches = LibraryPaths.Caches(root: tmp.appendingPathComponent("caches"))
        let bookID = UUID()

        let result = try ThumbnailPipeline.process(coverData: nil, bookID: bookID, paths: paths, caches: caches)

        XCTAssertEqual(result, .skippedNoCover)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cover(bookID: bookID).path))
        for size in ThumbnailSize.allCases {
            XCTAssertFalse(FileManager.default.fileExists(atPath: caches.thumbnail(bookID: bookID, size: size).path))
        }
    }

    func testCorruptCoverDataWritesNothingAndReports() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = LibraryPaths(root: tmp.appendingPathComponent("lib"))
        let caches = LibraryPaths.Caches(root: tmp.appendingPathComponent("caches"))
        let bookID = UUID()
        try FileManager.default.createDirectory(at: paths.bookDir(bookID), withIntermediateDirectories: true)

        let result = try ThumbnailPipeline.process(coverData: Data("not an image".utf8), bookID: bookID,
                                                    paths: paths, caches: caches)

        XCTAssertEqual(result, .failedInvalidImage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cover(bookID: bookID).path))
        for size in ThumbnailSize.allCases {
            XCTAssertFalse(FileManager.default.fileExists(atPath: caches.thumbnail(bookID: bookID, size: size).path))
        }
    }
}
