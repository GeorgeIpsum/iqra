import XCTest
@testable import IqraReader

final class SchemeHandlerTests: XCTestCase {
    var bookURL: URL!
    var bookID: UUID!
    var resolver: BookResourceResolver!

    override func setUpWithError() throws {
        bookID = UUID()
        bookURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".epub")
        try Data("fake epub bytes".utf8).write(to: bookURL)
        resolver = BookResourceResolver(bookID: bookID, bookFileURL: bookURL)
    }

    func url(_ path: String) -> URL {
        URL(string: "iqra-book://\(bookID.uuidString.lowercased())\(path)")!
    }

    func testServesBookBytes() throws {
        let r = try XCTUnwrap(resolver.response(for: url("/book.epub")))
        XCTAssertEqual(r.data, Data("fake epub bytes".utf8))
        XCTAssertEqual(r.mimeType, "application/epub+zip")
    }

    func testServesVendoredJSWithCorrectMIME() throws {
        let r = try XCTUnwrap(resolver.response(for: url("/vendor/foliate-js/view.js")))
        XCTAssertEqual(r.mimeType, "text/javascript")
        XCTAssertTrue(String(decoding: r.data, as: UTF8.self).contains("foliate-view"))
    }

    func testRejectsWrongHost() {
        let other = URL(string: "iqra-book://\(UUID().uuidString.lowercased())/book.epub")!
        XCTAssertNil(resolver.response(for: other))
    }

    func testRejectsPathTraversal() {
        XCTAssertNil(resolver.response(for: url("/vendor/foliate-js/../../secrets")))
        XCTAssertNil(resolver.response(for: url("/../etc/passwd")))
    }

    func testUnknownPathIs404() {
        XCTAssertNil(resolver.response(for: url("/nope.js")))
    }

    func testCSPForbidsRemoteScript() {
        let csp = BookResourceResolver.contentSecurityPolicy
        XCTAssertTrue(csp.contains("script-src 'self'"))
        XCTAssertTrue(csp.contains("form-action 'none'"))
        XCTAssertFalse(csp.contains("unsafe-eval"))
    }
}
