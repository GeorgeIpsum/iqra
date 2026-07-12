import XCTest
import IqraCore
@testable import IqraLibrary

final class PDFMetadataExtractorTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func testExtractsInfoDictAndRendersCover() throws {
        let url = try Fixtures.makePDF(title: "Design Patterns", author: "Gamma et al.", dir: dir)
        guard case let .extracted(meta, coverData) = PDFMetadataExtractor.extract(fileURL: url) else {
            return XCTFail("expected extraction")
        }
        XCTAssertEqual(meta.title, "Design Patterns")
        XCTAssertEqual(meta.contributors.map(\.name), ["Gamma et al."])
        let cover = try XCTUnwrap(coverData)
        XCTAssertGreaterThan(cover.count, 100) // a real JPEG render, not a stub
    }

    func testFallsBackToFilenameWhenNoTitle() throws {
        let url = try Fixtures.makePDF(title: nil, author: nil, dir: dir)
        guard case let .extracted(meta, _) = PDFMetadataExtractor.extract(fileURL: url) else {
            return XCTFail("expected extraction")
        }
        XCTAssertEqual(meta.title, url.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(meta.contributors.isEmpty)
    }

    func testGarbageIsRejectedAsCorrupt() throws {
        let url = dir.appendingPathComponent("bad.pdf")
        try Data("%PDF-1.7 not really".utf8).write(to: url)
        XCTAssertEqual(PDFMetadataExtractor.extract(fileURL: url), .rejected(.corruptContainer))
    }

    func testEncryptedPDFIsRejectedAsDRM() throws {
        let url = try Fixtures.makePDF(title: "Secret", author: "Someone", password: "s3cr3t", dir: dir)
        XCTAssertEqual(PDFMetadataExtractor.extract(fileURL: url), .rejected(.drmProtected))
    }
}
