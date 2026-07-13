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

/// Same skeleton as `makeFixtureEPUB`, but ch1's body carries a hostile payload: an inline
/// `<script>` and an `<img onerror=...>`, both of which try to (a) mark the page's *own*
/// global scope as pwned and (b) forge a native "relocate" message with an out-of-range
/// spineIndex/totalProgression/cfi. foliate-js deliberately does not strip inline scripts from
/// chapter content (see the "TODO: replace inline scripts? probably not worth the trouble"
/// comment in the vendored epub.js) and renders each section inside a sandboxed
/// `<iframe sandbox="allow-same-origin allow-scripts">` (paginator.js) — so this is exactly the
/// content a malicious/compromised EPUB could ship. The claim under test is that book content
/// scripts can never influence the app: the CSP (script-src 'self', inherited by the blob:
/// iframe) should block the inline script/handler outright, and even if it ran, the
/// main-frame-only guard in `EPUBNavigator`'s `MessageProxy` should reject any message that
/// didn't come from the top-level bridge page.
private func makeHostileFixtureEPUB(title: String, paragraphs: Int, dir: URL) throws -> URL {
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
    let forgedPostMessage = """
        window.__pwned = true; \
        window.webkit?.messageHandlers?.iqra?.postMessage({type:'relocate',spineIndex:99,totalProgression:0.99,cfi:'epubcfi(/6/999)'})
        """
    try add("OEBPS/ch1.xhtml", """
        <html><body><h1>One</h1>
        <script>\(forgedPostMessage)</script>
        <img src="x" onerror="\(forgedPostMessage)">
        \(body)</body></html>
        """)
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
        XCTAssertTrue(locator.totalProgression.isFinite, "totalProgression must never be NaN/Infinity")
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

    /// Pins the CFI-precedence fix in the "ready" handler: `lastLocator?.cfi ??
    /// initialLocator?.cfi`. A WebContent-process crash mid-session must recover to the
    /// most recently visited position, not silently rewind to wherever the navigator was
    /// constructed (spec "Process-kill recovery contract"). Simulates the crash by
    /// invoking the public recovery entry point, `webViewWebContentProcessDidTerminate`,
    /// directly — it triggers the same reload/ready/relocate path a real WebContent death
    /// would, without needing to actually kill the content process in a test harness.
    ///
    /// `initialLocator` must be a genuine, *different* CFI from the deep position for this
    /// test to actually discriminate the fix (if it's nil, both orderings of `??` fall
    /// through to `lastLocator` identically and the test is vacuous — confirmed by a
    /// mutation check while writing this test). So we first seed a real start-of-book CFI
    /// from a throwaway navigator and freeze it as `initialLocator` on the navigator under
    /// test, mirroring how a real caller would pass in the last-persisted locator.
    @MainActor
    func testCrashRecoveryRestoresDeepPositionNotStart() async throws {
        let epub = try makeFixtureEPUB(title: "Recovery", paragraphs: 120, dir: dir)

        let seedNav = EPUBNavigator(bookID: UUID(), bookFileURL: epub,
                                    initialLocator: nil, settings: .default)
        seedNav.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let seedRecorder = DelegateRecorder()
        seedNav.delegate = seedRecorder
        let seedRelocated = expectation(description: "seed relocated")
        seedRelocated.assertForOverFulfill = false
        seedRecorder.onRelocate = { seedRelocated.fulfill() }
        seedNav.start()
        await fulfillment(of: [seedRelocated], timeout: 30)
        let startLocator = try XCTUnwrap(seedRecorder.locators.first)
        XCTAssertLessThan(startLocator.totalProgression, 0.3) // sanity: genuinely near the start

        let nav = EPUBNavigator(bookID: UUID(), bookFileURL: epub,
                                initialLocator: startLocator, settings: .default)
        nav.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let recorder = DelegateRecorder()
        nav.delegate = recorder
        let loaded = expectation(description: "loaded")
        recorder.onLoad = { loaded.fulfill() }
        nav.start()
        await fulfillment(of: [loaded], timeout: 30)

        // jump deep into the book so lastLocator diverges from the frozen initialLocator
        let jumped = expectation(description: "jumped")
        jumped.assertForOverFulfill = false
        recorder.onRelocate = {
            if (recorder.locators.last?.totalProgression ?? 0) > 0.5 { jumped.fulfill() }
        }
        nav.goTo(fraction: 0.8)
        await fulfillment(of: [jumped], timeout: 30)

        // A single goTo can emit more than one relocate as the renderer settles (see the
        // other tests' `assertForOverFulfill = false`) — settling relocates from the
        // goTo(0.8) above can still be trickling in for a bit. Anchor "post-recovery" on
        // the reloaded page's own "loaded" post rather than "the next relocate we happen
        // to see" — a stray pre-reload relocate arriving late would otherwise still carry
        // the deep CFI and let a buggy recovery path pass by accident. bridge.js always
        // posts "loaded" before its own "relocate" within a single start() run, so once
        // this second "loaded" fires, any relocate we see afterward is genuinely from the
        // reloaded page's recovery navigation, not a leftover from before the crash.
        //
        // Snapshot `recorder.locators.count` from *inside* the "loaded" callback itself —
        // i.e. at the instant the reloaded page's "loaded" fires — rather than earlier
        // (e.g. right as the crash is triggered). Capturing it earlier would be too eager:
        // goTo(0.8)'s settling relocates can still be arriving right up until the reload
        // actually swaps in the new page, so a count taken before that point could still
        // count late pre-crash stragglers as "post-recovery" (confirmed: an earlier version
        // of this fix that snapshotted the count before triggering the reload still passed
        // even with the ready-handler's CFI precedence deliberately flipped back — a false
        // pass caused by exactly this false-positive). Capturing it here, synchronously in
        // the same callback that fulfills `reloaded`, is safe: no further pre-crash relocate
        // can land after this instant (this run's `loaded` has already posted), yet nothing
        // async has happened yet either, so it can't itself race.
        var preRecoveryLocatorCount = 0
        let reloaded = expectation(description: "reloaded")
        recorder.onLoad = {
            preRecoveryLocatorCount = recorder.locators.count
            reloaded.fulfill()
        }
        nav.webViewWebContentProcessDidTerminate(nav.webView)
        await fulfillment(of: [reloaded], timeout: 30)

        // simulate WebContent process death: the page reloads, bridge.js posts "ready"
        // again, and the ready handler must re-send lastLocator's CFI (the deep position
        // just reached), not initialLocator's (the frozen start-of-book position).
        //
        // Race: a recovery relocate can land in the scheduling gap between the
        // `await fulfillment(of: [reloaded], ...)` above returning and the `onRelocate`
        // assignment below being reached — the WKWebView message dispatch isn't
        // synchronized with this test's suspension/resumption. If that happens, the
        // relocate fires whatever `onRelocate` closure was installed *before* this point
        // (the stale "jumped" one from the goTo(0.8) step above), which silently
        // swallows it (its expectation already fulfilled, `assertForOverFulfill = false`)
        // and `recovered` would never fire, timing the test out. Close the gap by
        // checking synchronously — everything here is @MainActor, so this
        // check-then-install has no `await` in between and can't itself race — whether a
        // qualifying relocate already landed in `recorder.locators` since
        // `preRecoveryLocatorCount`, fulfilling immediately if so, and only installing the
        // listener otherwise.
        let recovered = expectation(description: "recovered")
        recovered.assertForOverFulfill = false
        func isPostRecoveryDeepRelocate() -> Bool {
            recorder.locators[preRecoveryLocatorCount...].contains { $0.totalProgression > 0.5 }
        }
        if isPostRecoveryDeepRelocate() {
            recovered.fulfill()
        } else {
            recorder.onRelocate = {
                if isPostRecoveryDeepRelocate() { recovered.fulfill() }
            }
        }
        await fulfillment(of: [recovered], timeout: 30)

        let restoredLocator = try XCTUnwrap(recorder.locators.last)
        XCTAssertGreaterThan(restoredLocator.totalProgression, 0.5,
                             "crash recovery must restore the freshest position, not the frozen initialLocator")
    }

    /// Security regression test for the claim "publisher scripts never execute [against the
    /// app]": opens a hostile EPUB (see `makeHostileFixtureEPUB`) whose chapter content carries
    /// an inline `<script>` and an `<img onerror>` that both try to mark the page as pwned and
    /// forge a native relocate message with an out-of-range spineIndex/totalProgression/cfi.
    /// Two independent layers are expected to defeat this: the CSP (script-src 'self', which
    /// the blob: content iframe inherits from the top-level bridge page) should block the
    /// inline script/handler from running at all, and even if it ran, `EPUBNavigator`'s
    /// `MessageProxy` only forwards messages whose `frameInfo.isMainFrame` is true — a content
    /// iframe's postMessage call would be dropped before reaching the delegate.
    @MainActor
    func testHostileEPUBCannotEscapeSandboxOrForgeRelocate() async throws {
        let epub = try makeHostileFixtureEPUB(title: "Hostile", paragraphs: 60, dir: dir)
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

        // The hostile chapter has already rendered into its content iframe by the time
        // "loaded"/the first "relocate" fired. Give any script/onerror handler that did run a
        // generous extra window to attempt its forged postMessage before asserting.
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // (a) The script (if it ran at all) ran inside a content iframe's own window, not the
        // top-level bridge page's — assert the bridge page's global scope was never polluted.
        let pwned = try? await nav.webView.evaluateJavaScript("window.__pwned === true")
        XCTAssertNotEqual(pwned as? Bool, true,
            "hostile chapter content must never be able to set state visible on the " +
            "top-level bridge page's window")

        // (b) The forged relocate must never reach the delegate: neither the CSP-blocked
        // script/handler nor (as defense in depth) the main-frame-only message guard should
        // let it through.
        XCTAssertFalse(recorder.locators.contains { $0.spineIndex == 99 },
            "forged spineIndex from chapter content must never reach the delegate")
        XCTAssertFalse(recorder.locators.contains { abs($0.totalProgression - 0.99) < 0.0001 },
            "forged totalProgression from chapter content must never reach the delegate")
        XCTAssertFalse(recorder.locators.contains { $0.cfi == "epubcfi(/6/999)" },
            "forged CFI from chapter content must never reach the delegate")
    }
}
