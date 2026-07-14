// Tests/IqraReaderTests/EPUBNavigatorSearchTests.swift
import XCTest
import WebKit
import ZIPFoundation
@testable import IqraReader

@MainActor
private final class SearchRecorder: NavigatorDelegate {
    var hits: [SearchHit] = []
    var finished = false
    var relocations: [Locator] = []
    var onLoad: (() -> Void)?
    var onFinish: (() -> Void)?
    var onRelocate: (() -> Void)?
    func navigatorDidLoad(title: String?, toc: [TOCItem]) { onLoad?() }
    func navigator(didRelocate locator: Locator) { relocations.append(locator); onRelocate?() }
    func navigator(didFail message: String) { XCTFail("reader error: \(message)") }
    func navigator(didFindSearchHit hit: SearchHit) { hits.append(hit) }
    func navigatorDidFinishSearch() { finished = true; onFinish?() }
}

final class EPUBNavigatorSearchTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func makeEPUB() throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".epub")
        let a = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        func add(_ n: String, _ t: String) throws {
            let d = Data(t.utf8)
            try a.addEntry(with: n, type: .file, uncompressedSize: Int64(d.count),
                           provider: { p, s in d.subdata(in: Int(p)..<Int(p)+s) })
        }
        try add("mimetype", "application/epub+zip")
        try add("META-INF/container.xml", #"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#)
        try add("content.opf", #"<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>S</dc:title><dc:language>en</dc:language><dc:identifier id="uid">urn:uuid:y</dc:identifier></metadata><manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>"#)
        try add("c1.xhtml", #"<html xmlns="http://www.w3.org/1999/xhtml"><body><p>The needle appears here in chapter one.</p></body></html>"#)
        try add("c2.xhtml", #"<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Another needle waits in chapter two, and a second needle too.</p></body></html>"#)
        return url
    }

    @MainActor
    func testSearchFindsHitsAcrossSectionsAndNavigates() async throws {
        let rec = SearchRecorder()
        let nav = EPUBNavigator(bookID: UUID(), bookFileURL: try makeEPUB(),
                                initialLocator: nil, settings: .default)
        nav.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        nav.delegate = rec
        let loaded = expectation(description: "loaded"); rec.onLoad = { loaded.fulfill() }
        nav.start(); await fulfillment(of: [loaded], timeout: 30)

        let done = expectation(description: "searchDone"); rec.onFinish = { done.fulfill() }
        nav.search(query: "needle")
        await fulfillment(of: [done], timeout: 30)

        XCTAssertGreaterThanOrEqual(rec.hits.count, 3, "3 occurrences of 'needle' across two sections")
        XCTAssertTrue(rec.hits.allSatisfy { $0.cfi.hasPrefix("epubcfi(") })
        XCTAssertTrue(rec.hits.contains { $0.excerptMatch.lowercased().contains("needle") })

        // Navigate to the last hit (in chapter two) and confirm a relocate follows.
        let moved = expectation(description: "moved"); moved.assertForOverFulfill = false
        rec.onRelocate = { moved.fulfill() }
        nav.goTo(cfi: rec.hits.last!.cfi)
        await fulfillment(of: [moved], timeout: 30)

        nav.clearSearch() // must not error
    }
}
