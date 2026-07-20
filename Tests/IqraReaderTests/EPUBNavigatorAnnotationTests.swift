// Tests/IqraReaderTests/EPUBNavigatorAnnotationTests.swift
import XCTest
import WebKit
import ZIPFoundation
@testable import IqraReader

@MainActor
private final class AnnRecorder: NavigatorDelegate {
    var loaded = false
    var selections: [SelectionInfo?] = []
    var tapped: [UUID] = []
    var onLoad: (() -> Void)?
    var onSelect: (() -> Void)?
    var onTap: (() -> Void)?
    func navigatorDidLoad(title: String?, toc: [TOCItem]) { loaded = true; onLoad?() }
    func navigator(didRelocate locator: Locator) {}
    func navigator(didFail message: String) { XCTFail("reader error: \(message)") }
    func navigator(didChangeSelection selection: SelectionInfo?) { selections.append(selection); onSelect?() }
    func navigator(didTapAnnotation id: UUID) { tapped.append(id); onTap?() }
}

final class EPUBNavigatorAnnotationTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Minimal EPUB with a paragraph of known text to select.
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
        try add("content.opf", #"<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Ann</dc:title><dc:language>en</dc:language><dc:identifier id="uid">urn:uuid:x</dc:identifier></metadata><manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>"#)
        try add("c1.xhtml", #"<html xmlns="http://www.w3.org/1999/xhtml"><body><p id="target">The quick brown fox jumps over the lazy dog and keeps running for a while.</p></body></html>"#)
        return url
    }

    /// Two-section EPUB, each section a single short paragraph with its own distinguishable
    /// text, for a section-turn / overlay-redraw test (Fix 6).
    func makeTwoSectionEPUB() throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".epub")
        let a = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        func add(_ n: String, _ t: String) throws {
            let d = Data(t.utf8)
            try a.addEntry(with: n, type: .file, uncompressedSize: Int64(d.count),
                           provider: { p, s in d.subdata(in: Int(p)..<Int(p)+s) })
        }
        try add("mimetype", "application/epub+zip")
        try add("META-INF/container.xml", #"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#)
        try add("content.opf", #"<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Ann2</dc:title><dc:language>en</dc:language><dc:identifier id="uid">urn:uuid:z</dc:identifier></metadata><manifest><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>"#)
        try add("c1.xhtml", #"<html xmlns="http://www.w3.org/1999/xhtml"><body><p id="target">The quick brown fox jumps over the lazy dog and keeps running for a while.</p></body></html>"#)
        try add("c2.xhtml", #"<html xmlns="http://www.w3.org/1999/xhtml"><body><p id="target2">A sleepy turtle napped through the whole afternoon beneath a wide fig tree.</p></body></html>"#)
        return url
    }

    @MainActor
    fileprivate func makeNavigator(_ recorder: AnnRecorder, epubURL: URL? = nil) throws -> EPUBNavigator {
        let nav = EPUBNavigator(bookID: UUID(), bookFileURL: try epubURL ?? makeEPUB(),
                                initialLocator: nil, settings: .default)
        nav.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        nav.delegate = recorder
        return nav
    }

    /// bridge.js posts "loaded" (which the Swift side awaits) before `await view.init(...)`
    /// finishes — `view.init` is what actually renders the first section into the
    /// renderer. So immediately after the "loaded" expectation fires,
    /// `renderer.getContents()` can still be empty. Poll deterministically (plain
    /// synchronous boolean-returning scripts — this WKWebView's `evaluateJavaScript`
    /// does not auto-await a Promise-valued completion, so the poll must not itself
    /// return one) instead of assuming the section is already rendered.
    @MainActor
    fileprivate func waitForFirstSectionRendered(_ nav: EPUBNavigator) async throws {
        for _ in 0..<150 {
            let ready = (try? await nav.webView.evaluateJavaScript(
                "document.querySelector('foliate-view').renderer.getContents().length > 0"
            ) as? Bool) ?? false
            if ready { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("renderer never populated getContents() with a rendered section")
    }

    @MainActor
    func testSelectionReportsTextAndRangeCFI() async throws {
        let rec = AnnRecorder(); let nav = try makeNavigator(rec)
        let loaded = expectation(description: "loaded"); rec.onLoad = { loaded.fulfill() }
        nav.start(); await fulfillment(of: [loaded], timeout: 30)
        try await waitForFirstSectionRendered(nav)

        // Drive a real selection over the paragraph text inside the section iframe, then fire pointerup.
        let selected = expectation(description: "selected"); selected.assertForOverFulfill = false
        rec.onSelect = { if rec.selections.last??.text.isEmpty == false { selected.fulfill() } }
        try await nav.webView.evaluateJavaScript("""
            (() => {
              const iframe = document.querySelector('foliate-view').renderer.getContents()[0].doc;
              const p = iframe.getElementById('target');
              const r = iframe.createRange(); r.selectNodeContents(p);
              const sel = iframe.getSelection(); sel.removeAllRanges(); sel.addRange(r);
              p.dispatchEvent(new PointerEvent('pointerup', { bubbles: true }));
            })()
            """)
        await fulfillment(of: [selected], timeout: 30)
        let info = try XCTUnwrap(rec.selections.last ?? nil)
        XCTAssertTrue(info.text.contains("quick brown fox"))
        XCTAssertTrue(info.cfi.hasPrefix("epubcfi("))
        XCTAssertEqual(info.textContext?.highlight, info.text)
    }

    @MainActor
    func testAddAnnotationDrawsAndTapReportsID() async throws {
        let rec = AnnRecorder(); let nav = try makeNavigator(rec)
        let loaded = expectation(description: "loaded"); rec.onLoad = { loaded.fulfill() }
        nav.start(); await fulfillment(of: [loaded], timeout: 30)
        try await waitForFirstSectionRendered(nav)

        // Get a real range CFI for the paragraph via the bridge's own getCFI.
        let cfi = try await nav.webView.evaluateJavaScript("""
            (() => {
              const view = document.querySelector('foliate-view');
              const iframe = view.renderer.getContents()[0].doc;
              const p = iframe.getElementById('target');
              const r = iframe.createRange(); r.selectNodeContents(p);
              return view.getCFI(0, r);
            })()
            """) as? String
        let annotationCFI = try XCTUnwrap(cfi)

        // The paginator creates a fresh Overlayer for every rendered section regardless of
        // whether any annotation is ever added (see paginator.js's unconditional
        // `create-overlayer` dispatch), so merely checking that `overlayer.hitTest` exists is
        // tautological. Instead, snapshot the overlayer's actual drawn SVG children
        // (Overlayer#add in overlayer.js appends one <g> per drawn annotation to
        // `overlayer.element`) before calling addAnnotation, then poll until that count
        // increases by exactly one -- proving our call really drew a highlight.
        let initialOverlayChildCount = try await nav.webView.evaluateJavaScript("""
            document.querySelector('foliate-view').renderer.getContents()[0].overlayer.element.childElementCount
            """) as? Int
        let beforeCount = try XCTUnwrap(initialOverlayChildCount)

        let id = UUID()
        let annotation = Annotation(id: id, kind: .highlight,
                                    locator: Locator(spineIndex: 0, cfi: annotationCFI, totalProgression: 0.1),
                                    color: .yellow, note: nil, createdAt: Date(), modifiedAt: Date())
        nav.addAnnotation(annotation)

        var afterCount = beforeCount
        for _ in 0..<100 {
            afterCount = try await nav.webView.evaluateJavaScript("""
                document.querySelector('foliate-view').renderer.getContents()[0].overlayer.element.childElementCount
                """) as? Int ?? beforeCount
            if afterCount == beforeCount + 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(afterCount, beforeCount + 1,
                        "addAnnotation should draw exactly one new SVG element into the overlayer")

        // Simulate a tap on the annotation via the view's showAnnotation path.
        let tapped = expectation(description: "tapped"); tapped.assertForOverFulfill = false
        rec.onTap = { tapped.fulfill() }
        try await nav.webView.evaluateJavaScript("""
            document.querySelector('foliate-view').showAnnotation({ value: \(jsStringLiteral(annotationCFI)) });
            true
            """)
        await fulfillment(of: [tapped], timeout: 30)
        XCTAssertEqual(rec.tapped.last, id)

        nav.removeAnnotation(annotation) // must not throw / error
    }

    /// Fix 6: proves the `create-overlay` re-add mechanism actually redraws an annotation
    /// after a section turn, not just that `addAnnotation` draws on the currently-visible
    /// section. foliate-js's paginator keeps exactly one page-view alive at a time
    /// (`#createView` destroys the previous view's iframe + overlayer before creating the
    /// next), so leaving section 1 for good tears its overlayer down entirely; returning to
    /// it later creates a brand-new overlayer and fires `create-overlayer` -> bridge.js's
    /// `create-overlay` handler, which must walk its tracked annotations and redraw whatever
    /// is anchored in section 1. This is the simpler of the two variants the fix calls for
    /// (annotate section 1, leave, come back, assert the redraw) — chosen because deriving a
    /// stable section-2 CFI up front would need an extra round of section-switching with no
    /// added coverage of the mechanism under test.
    @MainActor
    func testAnnotationRedrawnAfterReturningFromAnotherSection() async throws {
        let rec = AnnRecorder()
        let nav = try makeNavigator(rec, epubURL: try makeTwoSectionEPUB())
        let loaded = expectation(description: "loaded"); rec.onLoad = { loaded.fulfill() }
        nav.start(); await fulfillment(of: [loaded], timeout: 30)
        try await waitForFirstSectionRendered(nav)

        // Anchor an annotation in section 1 (the section currently showing).
        let cfi = try await nav.webView.evaluateJavaScript("""
            (() => {
              const view = document.querySelector('foliate-view');
              const iframe = view.renderer.getContents()[0].doc;
              const p = iframe.getElementById('target');
              const r = iframe.createRange(); r.selectNodeContents(p);
              return view.getCFI(0, r);
            })()
            """) as? String
        let section1CFI = try XCTUnwrap(cfi)
        nav.addAnnotation(Annotation(id: UUID(), kind: .highlight,
                                     locator: Locator(spineIndex: 0, cfi: section1CFI, totalProgression: 0.05),
                                     color: .yellow, note: nil, createdAt: Date(), modifiedAt: Date()))

        // Confirm it actually drew while section 1 was current (guards against a vacuous test).
        var drawnBefore = 0
        for _ in 0..<100 {
            drawnBefore = try await nav.webView.evaluateJavaScript("""
                document.querySelector('foliate-view').renderer.getContents()[0].overlayer.element.childElementCount
                """) as? Int ?? 0
            if drawnBefore == 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(drawnBefore, 1, "annotation should draw immediately while its section is current")

        // Leave section 1 for section 2 -- this destroys section 1's page-view/overlayer.
        nav.goTo(fraction: 0.9)
        var onSectionTwo = false
        for _ in 0..<150 {
            onSectionTwo = (try? await nav.webView.evaluateJavaScript("""
                document.querySelector('foliate-view').renderer.getContents()[0].index === 1
                """) as? Bool) ?? false
            if onSectionTwo { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(onSectionTwo, "goTo(fraction: 0.9) should have crossed into section 2")

        // Return to section 1 by CFI: a fresh overlayer is created there, and bridge.js's
        // `create-overlay` handler must redraw the annotation still registered for it.
        nav.goTo(cfi: section1CFI)
        var redrawnCount = -1
        for _ in 0..<150 {
            redrawnCount = try await nav.webView.evaluateJavaScript("""
                (() => {
                  const c = document.querySelector('foliate-view').renderer.getContents()[0];
                  return c.index === 0 ? c.overlayer.element.childElementCount : -1;
                })()
                """) as? Int ?? -1
            if redrawnCount == 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(redrawnCount, 1,
                       "returning to section 1 must redraw its registered annotation via create-overlay")
    }
}

/// Helper: JSON-encode a string as a JS literal for embedding in evaluateJavaScript.
private func jsStringLiteral(_ s: String) -> String {
    let data = (try? JSONEncoder().encode([s])) ?? Data("[\"\"]".utf8)
    return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
}
