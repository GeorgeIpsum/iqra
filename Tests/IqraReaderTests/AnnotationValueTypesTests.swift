import XCTest
@testable import IqraReader

final class AnnotationValueTypesTests: XCTestCase {
    func testLocatorCarriesTextContextRoundTrip() throws {
        let loc = Locator(spineIndex: 2, spineHref: "ch2", cfi: "epubcfi(/6/4,/1:0,/1:5)",
                          progressionInChapter: 0.1, totalProgression: 0.3, tocLabel: "Two",
                          textContext: TextContext(before: "the ", highlight: "quick", after: " brown"))
        let data = try JSONEncoder().encode(loc)
        XCTAssertEqual(try JSONDecoder().decode(Locator.self, from: data), loc)
    }

    func testLocatorTextContextDefaultsNilAndDecodesLegacyJSON() throws {
        // a locator persisted by M2 (no textContext key) must still decode
        let legacy = Data(#"{"spineIndex":1,"totalProgression":0.2}"#.utf8)
        let loc = try JSONDecoder().decode(Locator.self, from: legacy)
        XCTAssertNil(loc.textContext)
        XCTAssertEqual(loc.spineIndex, 1)
    }

    func testHighlightColorCSSIsHex() {
        for c in HighlightColor.allCases {
            XCTAssertTrue(c.cssColor.hasPrefix("#"), "\(c) should map to a hex color")
        }
        XCTAssertEqual(Set(HighlightColor.allCases.map(\.cssColor)).count, 5) // all distinct
    }

    func testAnnotationRoundTrip() throws {
        let a = Annotation(id: UUID(), kind: .note,
                           locator: Locator(spineIndex: 0, cfi: "epubcfi(/6/2,/1:0,/1:3)", totalProgression: 0.1),
                           color: .green, note: "hm", createdAt: Date(timeIntervalSince1970: 1),
                           modifiedAt: Date(timeIntervalSince1970: 2))
        let data = try JSONEncoder().encode(a)
        XCTAssertEqual(try JSONDecoder().decode(Annotation.self, from: data), a)
    }
}
