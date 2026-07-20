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

    /// Two occurrences of the query on ONE page must produce two hits with distinct ids
    /// (SwiftUI ForEach(searchHits) keys off SearchHit.id == cfi) and an excerpt that
    /// corresponds to the actual occurrence rather than always the first one on the page.
    @MainActor
    func testSearchWithMultipleOccurrencesOnOnePageHasDistinctIdsAndExcerpts() async throws {
        let url = try PDFFixtures.makePDF(pageCount: 1,
            texts: ["needle in a needle stack"], dir: dir)
        let nav = try XCTUnwrap(PDFNavigator(bookID: UUID(), bookFileURL: url, initialLocator: nil))
        nav.pdfView.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        let rec = PDFSearchRecorder(); nav.delegate = rec
        let loaded = expectation(description: "loaded"); rec.onLoad = { loaded.fulfill() }
        nav.start(); await fulfillment(of: [loaded], timeout: 10)

        let done = expectation(description: "done"); rec.onFinish = { done.fulfill() }
        nav.search(query: "needle")
        await fulfillment(of: [done], timeout: 10)

        XCTAssertEqual(rec.hits.count, 2)
        XCTAssertTrue(rec.hits.allSatisfy { $0.locator.spineIndex == 0 })
        XCTAssertEqual(Set(rec.hits.map(\.id)).count, rec.hits.count, "hit ids must be distinct")
        // "needle in a needle stack": the two occurrences have different surrounding text, so a
        // correct per-occurrence excerpt must differ; a bug that always excerpts the FIRST
        // occurrence would give every hit an empty excerptPre (and identical excerptPost).
        XCTAssertEqual(Set(rec.hits.map { $0.excerptPre + "|" + $0.excerptPost }).count, 2,
                       "each hit's excerpt should reflect its own occurrence, not always the first")
        XCTAssertTrue(rec.hits.contains { !$0.excerptPre.isEmpty },
                      "the second occurrence should have a non-empty prefix")
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
