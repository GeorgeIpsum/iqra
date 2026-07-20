// Tests/IqraReaderTests/PDFSearchTests.swift
import XCTest
import PDFKit
@testable import IqraReader

final class PDFSearchTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @MainActor
    func testSearchFindsHitsWithPageLocatorsAndExcerpts() async throws {
        let url = try PDFFixtures.makePDF(pageCount: 3,
            texts: ["the needle is here", "nothing", "another needle at the end"], dir: dir)
        let nav = try XCTUnwrap(PDFNavigator(bookID: UUID(), bookFileURL: url, initialLocator: nil))
        nav.pdfView.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        let rec = PDFSearchRecorder(); nav.delegate = rec
        let loaded = expectation(description: "loaded"); rec.onLoad = { loaded.fulfill() }
        nav.start(); await fulfillment(of: [loaded], timeout: 10)

        let done = expectation(description: "done"); rec.onFinish = { done.fulfill() }
        nav.search(query: "needle")
        await fulfillment(of: [done], timeout: 10)

        XCTAssertEqual(rec.hits.count, 2)
        XCTAssertEqual(Set(rec.hits.map { $0.locator.spineIndex }), [0, 2])   // pages 0 and 2
        XCTAssertTrue(rec.hits.allSatisfy { $0.excerptMatch.lowercased().contains("needle") })
    }
}

@MainActor
final class PDFSearchRecorder: NavigatorDelegate {
    var hits: [SearchHit] = []
    var onLoad: (() -> Void)?
    var onFinish: (() -> Void)?
    func navigatorDidLoad(title: String?, toc: [TOCItem]) { onLoad?() }
    func navigator(didRelocate locator: Locator) {}
    func navigator(didFail message: String) { XCTFail(message) }
    func navigator(didFindSearchHit hit: SearchHit) { hits.append(hit) }
    func navigatorDidFinishSearch() { onFinish?() }
}
