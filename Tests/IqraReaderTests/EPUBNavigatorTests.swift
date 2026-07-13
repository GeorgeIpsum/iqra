import XCTest
import WebKit
import ZIPFoundation
@testable import IqraReader

/// Minimal EPUB fixture builder. Deliberately duplicated from IqraLibraryTests's
/// Fixtures (test targets can't share code without a support target — revisit if a
/// third copy ever appears).
private func makeFixtureEPUB(title: String, paragraphs: Int, dir: URL) throws -> URL {
    let url = dir.appendingPathComponent(UUID().uuidString + ".epub")
    let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
    func add(_ name: String, _ text: String) throws {
        let data = Data(text.utf8)
        try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
                             provider: { p, s in data.subdata(in: Int(p)..<Int(p) + s) })
    }
    try add("mimetype", "application/epub+zip")
    try add("META-INF/container.xml", """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
    try add("OEBPS/content.opf", """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title>
            <dc:language>en</dc:language>
            <dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="ch1"/><itemref idref="ch2"/></spine>
        </package>
        """)
    try add("OEBPS/nav.xhtml", """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <body><nav epub:type="toc"><ol>
          <li><a href="ch1.xhtml">One</a></li><li><a href="ch2.xhtml">Two</a></li>
        </ol></nav></body></html>
        """)
    let body = (0..<paragraphs).map { "<p>Paragraph \($0) of steady prose for pagination.</p>" }
        .joined()
    try add("OEBPS/ch1.xhtml", "<html><body><h1>One</h1>\(body)</body></html>")
    try add("OEBPS/ch2.xhtml", "<html><body><h1>Two</h1>\(body)</body></html>")
    return url
}

@MainActor
private final class DelegateRecorder: NavigatorDelegate {
    var loaded: (title: String?, toc: [TOCItem])?
    var locators: [Locator] = []
    var errors: [String] = []
    var onLoad: (() -> Void)?
    var onRelocate: (() -> Void)?
    func navigatorDidLoad(title: String?, toc: [TOCItem]) {
        loaded = (title, toc); onLoad?()
    }
    func navigator(didRelocate locator: Locator) {
        locators.append(locator); onRelocate?()
    }
    func navigator(didFail message: String) { errors.append(message) }
}

final class EPUBNavigatorTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @MainActor
    func testOpensBookReportsTOCAndRelocates() async throws {
        let epub = try makeFixtureEPUB(title: "Bridge Test", paragraphs: 60, dir: dir)
        let nav = EPUBNavigator(bookID: UUID(), bookFileURL: epub,
                                initialLocator: nil, settings: .default)
        nav.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let recorder = DelegateRecorder()
        nav.delegate = recorder

        let loadExpectation = expectation(description: "loaded")
        recorder.onLoad = { loadExpectation.fulfill() }
        let relocateExpectation = expectation(description: "relocated")
        relocateExpectation.assertForOverFulfill = false
        recorder.onRelocate = { relocateExpectation.fulfill() }

        nav.start()
        await fulfillment(of: [loadExpectation, relocateExpectation], timeout: 30)

        XCTAssertEqual(recorder.loaded?.title, "Bridge Test")
        XCTAssertEqual(recorder.loaded?.toc.map(\.label), ["One", "Two"])
        let locator = try XCTUnwrap(recorder.locators.last)
        XCTAssertNotNil(locator.cfi)
        XCTAssertGreaterThanOrEqual(locator.totalProgression, 0)
        XCTAssertTrue(recorder.errors.isEmpty, "reader errors: \(recorder.errors)")
    }

    @MainActor
    func testGoToFractionMovesForwardAndCFIRestores() async throws {
        let epub = try makeFixtureEPUB(title: "Restore", paragraphs: 120, dir: dir)
        let nav = EPUBNavigator(bookID: UUID(), bookFileURL: epub,
                                initialLocator: nil, settings: .default)
        nav.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let recorder = DelegateRecorder()
        nav.delegate = recorder
        let loaded = expectation(description: "loaded")
        recorder.onLoad = { loaded.fulfill() }
        nav.start()
        await fulfillment(of: [loaded], timeout: 30)

        // jump deep into the book, capture the CFI there
        let jumped = expectation(description: "jumped")
        jumped.assertForOverFulfill = false
        recorder.onRelocate = {
            if (recorder.locators.last?.totalProgression ?? 0) > 0.5 { jumped.fulfill() }
        }
        nav.goTo(fraction: 0.8)
        await fulfillment(of: [jumped], timeout: 30)
        let deepLocator = try XCTUnwrap(recorder.locators.last)
        let deepCFI = try XCTUnwrap(deepLocator.cfi)

        // fresh navigator restoring from that locator lands at (approximately) the same place
        let nav2 = EPUBNavigator(bookID: UUID(), bookFileURL: epub,
                                 initialLocator: deepLocator, settings: .default)
        nav2.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let recorder2 = DelegateRecorder()
        nav2.delegate = recorder2
        let restored = expectation(description: "restored")
        restored.assertForOverFulfill = false
        recorder2.onRelocate = {
            if (recorder2.locators.last?.totalProgression ?? 0) > 0.5 { restored.fulfill() }
        }
        nav2.start()
        await fulfillment(of: [restored], timeout: 30)
        let restoredLocator = try XCTUnwrap(recorder2.locators.last)
        XCTAssertEqual(restoredLocator.totalProgression, deepLocator.totalProgression, accuracy: 0.05)
        XCTAssertNotNil(deepCFI) // the anchor that made the restore precise
    }
}
