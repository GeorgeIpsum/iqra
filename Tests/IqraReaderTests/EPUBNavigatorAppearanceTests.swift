import XCTest
import WebKit
import ZIPFoundation
@testable import IqraReader

final class EPUBNavigatorAppearanceTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Polls a JS expression until it returns the expected string (styles apply
    /// asynchronously after setAppearance).
    @MainActor
    private func waitForJS(_ webView: WKWebView, _ js: String, toEqual expected: String,
                           timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last: String? = nil
        while Date() < deadline {
            last = try? await webView.evaluateJavaScript(js) as? String
            if last == expected { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("JS \(js) == \(last ?? "nil"), expected \(expected)")
    }

    @MainActor
    func testThemeAndFlowChangesApplyToRenderedContent() async throws {
        let epub = try makeAppearanceFixtureEPUB(dir: dir)
        let nav = EPUBNavigator(bookID: UUID(), bookFileURL: epub,
                                initialLocator: nil, settings: .default)
        nav.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let recorder = AppearanceDelegateRecorder()
        nav.delegate = recorder
        let loaded = expectation(description: "loaded")
        recorder.onLoad = { loaded.fulfill() }
        nav.start()
        await fulfillment(of: [loaded], timeout: 30)

        // dark theme lands in the section iframe's computed style
        var dark = ReaderSettings.default
        dark.theme = .dark
        nav.apply(settings: dark)
        try await waitForJS(nav.webView, """
            getComputedStyle(document.querySelector('foliate-view')
                .renderer.getContents()[0].doc.body).backgroundColor
            """, toEqual: "rgb(18, 18, 18)")

        // flow switch flips the renderer attribute (paginated → scrolled)
        var scrolled = dark
        scrolled.flow = .scrolled
        nav.apply(settings: scrolled)
        try await waitForJS(nav.webView, """
            document.querySelector('foliate-view').renderer.getAttribute('flow')
            """, toEqual: "scrolled")
    }
}

// Minimal fixture + recorder local to this file (see Task 8's note on cross-target reuse).
@MainActor
private final class AppearanceDelegateRecorder: NavigatorDelegate {
    var onLoad: (() -> Void)?
    func navigatorDidLoad(title: String?, toc: [TOCItem]) { onLoad?() }
    func navigator(didRelocate locator: Locator) {}
    func navigator(didFail message: String) {}
}

private func makeAppearanceFixtureEPUB(dir: URL) throws -> URL {
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
          <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
    try add("content.opf", """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Appearance</dc:title><dc:language>en</dc:language>
            <dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier>
          </metadata>
          <manifest><item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="ch1"/></spine>
        </package>
        """)
    try add("ch1.xhtml", "<html><body><p>Styled paragraph.</p></body></html>")
    return url
}
