// Tests/IqraReaderTests/PDFAnnotationMappingTests.swift
import XCTest
import PDFKit
@testable import IqraReader

final class PDFAnnotationMappingTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func testRectQuadRoundTrip() {
        let r = CGRect(x: 10, y: 20, width: 100, height: 12)
        let q = PDFAnnotationMapping.quad(from: r)
        XCTAssertEqual(q.count, 8)
        let back = PDFAnnotationMapping.rect(from: q)
        XCTAssertEqual(back.minX, r.minX, accuracy: 0.001)
        XCTAssertEqual(back.minY, r.minY, accuracy: 0.001)
        XCTAssertEqual(back.width, r.width, accuracy: 0.001)
        XCTAssertEqual(back.height, r.height, accuracy: 0.001)
    }

    func testAnchorFromSelectionCarriesPageQuadsAndText() throws {
        let url = try PDFFixtures.makePDF(pageCount: 2, texts: ["highlight me", "other"], dir: dir)
        let doc = try XCTUnwrap(PDFDocument(url: url))
        // findString gives us a real PDFSelection on page 0
        let sel = try XCTUnwrap(doc.findString("highlight", withOptions: [.caseInsensitive]).first)
        let anchor = try XCTUnwrap(PDFAnnotationMapping.anchor(from: sel, in: doc))
        XCTAssertEqual(anchor.pageIndex, 0)
        XCTAssertFalse(anchor.quads.isEmpty)
        XCTAssertEqual(anchor.quads.first?.count, 8)
        XCTAssertTrue(anchor.textQuote.lowercased().contains("highlight"))
    }

    func testHighlightAnnotationsHaveBoundsAndColor() {
        let quads = [[0.0, 0, 100, 0, 0, 12, 100, 12]]
        let anns = PDFAnnotationMapping.highlightAnnotations(quads: quads, colorHex: "#F7D774")
        XCTAssertEqual(anns.count, 1)
        XCTAssertEqual(anns[0].bounds.width, 100, accuracy: 0.001)
        XCTAssertNotNil(anns[0].color)
    }
}
