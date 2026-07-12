import XCTest
import IqraCore
@testable import IqraLibrary

final class EPUBMetadataExtractorTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func testExtractsMetadataAndCover() throws {
        let url = try Fixtures.makeEPUB(title: "The Left Hand of Darkness", author: "Ursula K. Le Guin",
                                        isbn: "9780441478125", coverJPEG: Fixtures.tinyJPEG(), dir: dir)
        guard case let .extracted(meta, coverData) = EPUBMetadataExtractor.extract(fileURL: url) else {
            return XCTFail("expected extraction")
        }
        XCTAssertEqual(meta.title, "The Left Hand of Darkness")
        XCTAssertEqual(meta.titleSort, "Left Hand of Darkness, The")
        XCTAssertEqual(meta.contributors.map(\.name), ["Ursula K. Le Guin"])
        XCTAssertEqual(meta.contributors.first?.role, .author)
        XCTAssertTrue(meta.identifiers.contains(BookIdentifier(type: "isbn", value: "9780441478125")))
        XCTAssertEqual(meta.language, "en")
        XCTAssertNotNil(coverData)
    }

    func testEncryptedEPUBIsRejectedAsDRM() throws {
        let url = try Fixtures.makeEPUB(title: "Locked", author: "X", isbn: nil,
                                        encrypted: true, dir: dir)
        XCTAssertEqual(EPUBMetadataExtractor.extract(fileURL: url), .rejected(.drmProtected))
    }

    func testGarbageZipIsRejectedAsCorrupt() throws {
        let url = dir.appendingPathComponent("bad.epub")
        try Data("PK\u{03}\u{04}garbage".utf8).write(to: url)
        XCTAssertEqual(EPUBMetadataExtractor.extract(fileURL: url), .rejected(.corruptContainer))
    }
}
