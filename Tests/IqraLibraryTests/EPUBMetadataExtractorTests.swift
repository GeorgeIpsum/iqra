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
        XCTAssertEqual(meta.contributors.first?.sortName, "Le Guin, Ursula K.")
        XCTAssertTrue(meta.identifiers.contains(BookIdentifier(type: "isbn", value: "9780441478125")))
        XCTAssertEqual(meta.language, "en")
        XCTAssertNotNil(coverData)
    }

    func testAuthorSortHandlesCompoundSurnames() {
        XCTAssertEqual(EPUBMetadataExtractor.makeAuthorSort("Ursula K. Le Guin"), "Le Guin, Ursula K.")
        XCTAssertEqual(EPUBMetadataExtractor.makeAuthorSort("John von Neumann"), "von Neumann, John")
        XCTAssertEqual(EPUBMetadataExtractor.makeAuthorSort("Frank Herbert"), "Herbert, Frank")
        XCTAssertEqual(EPUBMetadataExtractor.makeAuthorSort("Plato"), "Plato")
    }

    func testEncryptedEPUBIsRejectedAsDRM() throws {
        let url = try Fixtures.makeEPUB(title: "Locked", author: "X", isbn: nil,
                                        encrypted: true, dir: dir)
        XCTAssertEqual(EPUBMetadataExtractor.extract(fileURL: url), .rejected(.drmProtected))
    }

    func testFontObfuscationOnlyEPUBIsExtracted() throws {
        let url = try Fixtures.makeEPUB(title: "Fonts OK", author: "X", isbn: nil, encryptionXML: """
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
                <EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
              </EncryptedData>
            </encryption>
            """, dir: dir)
        guard case .extracted = EPUBMetadataExtractor.extract(fileURL: url) else {
            return XCTFail("expected extraction to succeed for font-obfuscation-only encryption.xml")
        }
    }

    func testMixedFontAndContentEncryptionIsRejectedAsDRM() throws {
        let url = try Fixtures.makeEPUB(title: "Mixed", author: "X", isbn: nil, encryptionXML: """
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
                <EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
              </EncryptedData>
              <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
                <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
              </EncryptedData>
            </encryption>
            """, dir: dir)
        XCTAssertEqual(EPUBMetadataExtractor.extract(fileURL: url), .rejected(.drmProtected))
    }

    func testGarbageZipIsRejectedAsCorrupt() throws {
        let url = dir.appendingPathComponent("bad.epub")
        try Data("PK\u{03}\u{04}garbage".utf8).write(to: url)
        XCTAssertEqual(EPUBMetadataExtractor.extract(fileURL: url), .rejected(.corruptContainer))
    }
}
