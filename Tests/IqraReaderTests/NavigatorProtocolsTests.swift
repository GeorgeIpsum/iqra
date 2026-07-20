// Tests/IqraReaderTests/NavigatorProtocolsTests.swift
import XCTest
@testable import IqraReader

final class NavigatorProtocolsTests: XCTestCase {
    func testEPUBNavigatorConformsToAllCapabilities() {
        // Compile-time conformance is the assertion; a runtime check documents it.
        let type: Any.Type = EPUBNavigator.self
        XCTAssertTrue(type is Navigator.Type)
        XCTAssertTrue(type is (any TextSelectable.Type))
        XCTAssertTrue(type is (any RangeAnnotatable.Type))
        XCTAssertTrue(type is (any Searchable.Type))
        XCTAssertTrue(type is (any AppearanceConfigurable.Type))
    }

    func testLocatorAnchorKeyPrefersCFIElsePage() {
        XCTAssertEqual(Locator(spineIndex: 3, cfi: "epubcfi(/6/8)", totalProgression: 0.2).anchorKey,
                       "epubcfi(/6/8)")
        XCTAssertEqual(Locator(spineIndex: 7, cfi: nil, totalProgression: 0.5).anchorKey, "page:7")
    }

    func testLocatorPageQuadsRoundTripAndLegacyDecode() throws {
        let loc = Locator(spineIndex: 4, cfi: nil, totalProgression: 0.3,
                          pageQuads: [[0, 0, 10, 0, 0, 8, 10, 8]])
        XCTAssertEqual(try Locator.from(jsonData: loc.jsonData()), loc)
        // legacy locator with no pageQuads key decodes to nil
        let legacy = try Locator.from(jsonData: Data(#"{"spineIndex":1,"totalProgression":0.1}"#.utf8))
        XCTAssertNil(legacy.pageQuads)
    }
}
