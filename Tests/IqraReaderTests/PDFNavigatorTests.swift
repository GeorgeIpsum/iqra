import XCTest
import PDFKit
@testable import IqraReader

final class PDFNavigatorTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func testPageLocatorMath() {
        let mid = PDFNavigator.pageLocator(pageIndex: 5, pageCount: 11, tocLabel: nil)
        XCTAssertEqual(mid.spineIndex, 5)
        XCTAssertNil(mid.cfi)
        XCTAssertEqual(mid.totalProgression, 0.5, accuracy: 0.0001)
        // first page = 0, last = 1
        XCTAssertEqual(PDFNavigator.pageLocator(pageIndex: 0, pageCount: 11, tocLabel: nil).totalProgression, 0)
        XCTAssertEqual(PDFNavigator.pageLocator(pageIndex: 10, pageCount: 11, tocLabel: nil).totalProgression, 1)
        // single-page book doesn't divide by zero
        XCTAssertEqual(PDFNavigator.pageLocator(pageIndex: 0, pageCount: 1, tocLabel: nil).totalProgression, 0)
    }

    func testTOCEmptyForOutlinelessPDF() throws {
        let url = try PDFFixtures.makePDF(pageCount: 3, dir: dir)
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(PDFNavigator.toc(from: doc).count, 0)   // generated PDFs have no outline
    }

    @MainActor
    func testLoadsDocumentAndReportsLoadThenRelocate() async throws {
        let url = try PDFFixtures.makePDF(pageCount: 4, texts: ["Alpha", "Beta", "Gamma", "Delta"], dir: dir)
        let nav = try XCTUnwrap(PDFNavigator(bookID: UUID(), bookFileURL: url, initialLocator: nil))
        nav.pdfView.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        let recorder = PDFRecorder()
        nav.delegate = recorder
        let loaded = expectation(description: "loaded")
        recorder.onLoad = { loaded.fulfill() }
        nav.start()
        await fulfillment(of: [loaded], timeout: 10)
        XCTAssertEqual(nav.pageCount, 4)

        // navigate and observe a relocate
        let moved = expectation(description: "moved"); moved.assertForOverFulfill = false
        recorder.onRelocate = { if recorder.locators.last?.spineIndex ?? 0 >= 2 { moved.fulfill() } }
        nav.goTo(locator: PDFNavigator.pageLocator(pageIndex: 2, pageCount: 4, tocLabel: nil))
        await fulfillment(of: [moved], timeout: 10)
        XCTAssertEqual(recorder.locators.last?.spineIndex, 2)
    }
}

@MainActor
final class PDFRecorder: NavigatorDelegate {
    var loaded: (title: String?, toc: [TOCItem])?
    var locators: [Locator] = []
    var onLoad: (() -> Void)?
    var onRelocate: (() -> Void)?
    func navigatorDidLoad(title: String?, toc: [TOCItem]) { loaded = (title, toc); onLoad?() }
    func navigator(didRelocate locator: Locator) { locators.append(locator); onRelocate?() }
    func navigator(didFail message: String) { XCTFail("PDF error: \(message)") }
}
