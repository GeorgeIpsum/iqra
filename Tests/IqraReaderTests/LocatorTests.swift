import XCTest
@testable import IqraReader

final class LocatorTests: XCTestCase {
    func testLocatorJSONRoundTrip() throws {
        let locator = Locator(spineIndex: 4, spineHref: "OEBPS/ch4.xhtml",
                              cfi: "epubcfi(/6/10!/4/2/8,/1:5,/1:25)",
                              progressionInChapter: 0.31, totalProgression: 0.42,
                              tocLabel: "Chapter Four")
        let data = try locator.jsonData()
        XCTAssertEqual(try Locator.from(jsonData: data), locator)
    }

    func testDefaultSettings() {
        let s = ReaderSettings.default
        XCTAssertEqual(s.fontSizePercent, 100)
        XCTAssertEqual(s.flow, .paginated)
        XCTAssertEqual(s.theme, .light)
    }

    func testVendoredFoliateIsBundled() throws {
        let url = readerBundle.url(forResource: "view", withExtension: "js", subdirectory: "Vendor/foliate-js")
        XCTAssertNotNil(url, "vendored foliate-js must ship in the module bundle")
    }
}
