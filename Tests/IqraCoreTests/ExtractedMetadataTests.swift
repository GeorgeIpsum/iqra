import XCTest
import IqraCore

final class ExtractedMetadataTests: XCTestCase {
    func testTitleSortStripsLeadingArticleEnglish() {
        XCTAssertEqual(makeTitleSort("The Client", language: "en"), "Client, The")
        XCTAssertEqual(makeTitleSort("A Wizard of Earthsea", language: "en"), "Wizard of Earthsea, A")
        XCTAssertEqual(makeTitleSort("An Instance", language: "en"), "Instance, An")
    }

    func testTitleSortLeavesNonArticleAndUnknownLanguageAlone() {
        XCTAssertEqual(makeTitleSort("Their Eyes", language: "en"), "Their Eyes")
        XCTAssertEqual(makeTitleSort("The Client", language: "fr"), "The Client")
        XCTAssertEqual(makeTitleSort("The Client", language: nil), "Client, The")  // default English behavior
    }

    func testMetadataCodableRoundTrip() throws {
        let m = ExtractedMetadata(
            title: "T", titleSort: "T", language: "en", publisher: "P", bookDescription: nil,
            contributors: [Contributor(name: "Ursula K. Le Guin", sortName: "Le Guin, Ursula K.", role: .author)],
            identifiers: [BookIdentifier(type: "isbn", value: "9780141354491")]
        )
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(ExtractedMetadata.self, from: data), m)
    }
}
