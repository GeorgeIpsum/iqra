import XCTest
import IqraCore

final class FormatTypeTests: XCTestCase {
    func testFileExtensions() {
        XCTAssertEqual(FormatType.epub.fileExtension, "epub")
        XCTAssertEqual(FormatType.pdf.fileExtension, "pdf")
        XCTAssertEqual(FormatType.cbz.fileExtension, "cbz")
        XCTAssertEqual(FormatType.cbr.fileExtension, "cbr")
        XCTAssertEqual(FormatType.mobi.fileExtension, "mobi")
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(FormatType.epub)
        XCTAssertEqual(try JSONDecoder().decode(FormatType.self, from: data), .epub)
    }
}
