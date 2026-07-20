import XCTest
import ZIPFoundation
@testable import IqraReader

final class ComicExtractorTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A CBZ whose entries are deliberately out of lexicographic order (page 10 before page 2).
    func makeCBZ(pageNames: [String]) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".cbz")
        let a = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        try a.addEntry(with: "ComicInfo.xml", type: .file, uncompressedSize: Int64(12),
                       provider: { p, s in Data("<ComicInfo/>".utf8).subdata(in: Int(p)..<Int(p)+s) })
        for name in pageNames {
            let bytes = Data([0xFF, 0xD8, 0xFF, UInt8(name.count)])  // fake jpeg-ish, distinct per page
            try a.addEntry(with: name, type: .file, uncompressedSize: Int64(bytes.count),
                           provider: { p, s in bytes.subdata(in: Int(p)..<Int(p)+s) })
        }
        return url
    }

    func testExtractSortsNaturallyAndWritesManifest() throws {
        let cbz = try makeCBZ(pageNames: ["page10.jpg", "page2.jpg", "page1.jpg", "cover.png"])
        let cache = dir.appendingPathComponent("cache")
        let manifest = try ComicExtractor.extractCBZ(cbzURL: cbz, into: cache)

        XCTAssertEqual(manifest.pageCount, 4)
        // natural order via localizedStandardCompare: "cover.png" < "page1.jpg" < "page2.jpg" < "page10.jpg"
        // ('c' < 'p' lexically, and the digit runs 1 < 2 < 10 compare numerically, not lexically).
        let names = manifest.pages.map(\.fileName)
        XCTAssertEqual(names, ["0000.png", "0001.jpg", "0002.jpg", "0003.jpg"]) // re-indexed to sorted order
        // the page files exist on disk
        for p in manifest.pages {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: cache.appendingPathComponent(p.fileName).path))
        }
        // manifest reloads
        XCTAssertEqual(ComicExtractor.loadManifest(from: cache), manifest)
    }

    func testExcludesNonImagesAndJunk() throws {
        let cbz = try makeCBZ(pageNames: ["001.jpg", "__MACOSX/._001.jpg", ".DS_Store", "notes.txt"])
        let cache = dir.appendingPathComponent("cache")
        let manifest = try ComicExtractor.extractCBZ(cbzURL: cbz, into: cache)
        XCTAssertEqual(manifest.pageCount, 1)  // only 001.jpg
    }
}
