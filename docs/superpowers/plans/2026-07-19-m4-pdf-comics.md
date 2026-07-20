# M4 — PDF & Comics Reading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open a PDF and read it with page navigation, two-page spread, outline TOC, in-document search, text-selection highlights + notes, and bookmarks; and open a CBZ comic and page through it with a memory-safe image viewer, position restore, and bookmarks — all behind one shared navigator abstraction so the reader UI drives features by capability, not format.

**Architecture:** First split the flat `NavigatorDelegate` into a base `Navigator` protocol + capability protocols (`TextSelectable`, `RangeAnnotatable`, `Searchable`, `AppearanceConfigurable`) — the spec's protocol composition, now load-bearing because PDF has all capabilities and comics has none. `EPUBNavigator` (M2/M3) conforms to all; a new `PDFNavigator` (PDFKit) conforms to all; a new `ComicNavigator` (native paged image viewer) conforms to base + none. `ReaderViewModel` becomes format-neutral: it holds `any Navigator`, drives capabilities by conformance checks, and anchors bookmarks/positions on a format-neutral `Locator` (page index for PDF/comics, CFI for EPUB). The catalogue/annotation/reading-state model needs no schema change — the `Locator` gains additive optional PDF fields. Spec: `docs/superpowers/specs/2026-07-11-iqra-architecture-design.md` ("The other engines", "protocol composition", "PDF annotation anchors"). PDFKit + comics APIs verified against current Apple docs / the vendored codebase.

**Tech Stack:** Swift 5.10, PDFKit, ZIPFoundation (CBZ), ImageIO (downsampling), GRDB 7, SwiftUI, XcodeGen. No new Swift dependencies (CBR/Unrar deferred).

## Global Constraints

- Deployment floors: **iOS 17.0 / macOS 14.0**. Swift tools **5.10**.
- Runtime Swift dependencies stay **GRDB.swift + ZIPFoundation only**. PDFKit/ImageIO/CoreGraphics are system frameworks. **CBR is out of scope** — the research verdict is that RAR needs a vendored/non-OSI-licensed decoder (`Unrar.swift`, UnRAR license); `.cbr` stays quarantined this milestone. The viewer/cache/model layers are format-agnostic so CBR slots in later with no rework (tracked in `m1-followups.md`).
- Package boundaries unchanged: `IqraCore` imports Foundation only. `IqraLibrary` never imports UI or reader code (locators/annotations stay opaque JSON to it). `IqraReader` imports IqraCore + WebKit + **PDFKit** only, never IqraLibrary. The app is the composition point.
- **No schema change.** Reading position and annotations reuse the existing `reading_state` / `annotation` tables. `Locator.spineIndex` is the universal reading-order index (page index for PDF/comics); the annotation-ordering SQL (`json_extract(locator,'$.spineIndex')`) therefore orders PDF/comic bookmarks in page order for free.
- **PDF annotations never mutate the file** (spec): PDFKit `addAnnotation` mutates only the in-memory `PDFDocument`; the original PDF is never `write(to:)`-n. Stored highlights are `{pageIndex, quads (page space), textQuote}` in our DB and re-drawn as overlay annotations every open.
- **Comics: extract-to-cache** (spec): a CBZ is extracted once to an evictable `Caches/comics/<formatUUID>/` dir with a `manifest.json`; the pager reads page files by URL and keeps a small decode window (±1 page). Never load a whole comic into memory.
- Permanent tombstones, 5-color highlights, apply-sequence stamping, single-writer serialized DB — all as M1–M3.
- The sandboxed macOS app requires `com.apple.security.network.client` for WKWebView (already in `project.yml` from the M3 smoke-test fix) — do not remove it.
- All package logic lands with `swift test` coverage (PDFKit `PDFDocument`/search/annotation math is headless-testable; comic extraction is headless-testable). WKWebView EPUB tests stay green. Zero-warning builds. Commit per task; conventional-commit subjects.

## File Structure

```
Sources/IqraReader/
  NavigatorProtocols.swift        — Navigator base + capability protocols; TOCItem; NavigatorDelegate (tap → annotation id)
  Locator.swift                   — + pageQuads (PDF); + anchorKey; PDFAnchor helpers
  EPUBNavigator.swift             — conform to Navigator + all capabilities; goTo(locator:); carry annotation id
  ReaderAssets/bridge.js          — annotation entries carry `id`; show-annotation reports id
  PDFNavigator.swift              — NEW: PDFKit-backed Navigator + Searchable + TextSelectable + RangeAnnotatable + AppearanceConfigurable
  PDFAnnotationMapping.swift      — NEW: PDFSelection ↔ {pageIndex, quads, textQuote}; render/hit-test helpers (pure, testable)
  Comic/ComicManifest.swift       — NEW: ordered page manifest (Codable)
  Comic/ComicExtractor.swift      — NEW: CBZ → cache dir + manifest (ZIPFoundation, natural sort); pure/testable
  Comic/ComicNavigator.swift      — NEW: page-based Navigator (base only)
Sources/IqraLibrary/
  Import/ComicMetadataExtractor.swift — NEW: ComicInfo.xml + first-image cover (native, no reader import)
  Import/ImportPipeline.swift     — cbz becomes first-class (sniff → extract meta → import), cbr still quarantined
  LibraryPaths.swift              — + Caches.comicPagesDir(formatID:)
  Database/LibraryStore.swift     — openableFormat generalized to epub/pdf/cbz
App/Sources/
  ReaderViewModel.swift           — format-neutral: any Navigator, capability-driven, locator-neutral bookmarks/goTo
  NavigatorFactory.swift          — NEW: picks EPUB/PDF/Comic navigator by format
  ReaderScreen.swift              — hosts the right reader view by navigator kind; capability-gated chrome
  PDFReaderView.swift             — NEW: PDFKitView representable + thumbnail scrubber
  ComicReaderView.swift           — NEW: memory-windowed paged image viewer
Tests/IqraReaderTests/
  NavigatorProtocolsTests.swift, PDFNavigatorTests.swift, PDFAnnotationMappingTests.swift,
  PDFSearchTests.swift, ComicExtractorTests.swift, ComicNavigatorTests.swift, Support/PDFFixtures.swift, Support/ComicFixtures.swift
Tests/IqraLibraryTests/
  ComicImportTests.swift
```

---

## Phase A — Capability-protocol refactor (pre-work)

### Task 1: Capability protocols + EPUBNavigator conformance + tap-by-id

**Files:**
- Modify: `Sources/IqraReader/NavigatorProtocols.swift`, `Sources/IqraReader/Locator.swift`, `Sources/IqraReader/EPUBNavigator.swift`, `Sources/IqraReader/ReaderAssets/bridge.js`
- Modify: `App/Sources/ReaderViewModel.swift` (adapt to the new tap signature only — still concrete EPUBNavigator this task)
- Modify: `Tests/IqraReaderTests/EPUBNavigatorAnnotationTests.swift` (tap test asserts the id)
- Test: `Tests/IqraReaderTests/NavigatorProtocolsTests.swift`

**Interfaces:**
- Produces:

```swift
// Base protocol — every navigator (EPUB, PDF, comic)
@MainActor public protocol Navigator: AnyObject {
    var delegate: NavigatorDelegate? { get set }
    func start()
    func goTo(locator: Locator)   // unified navigation
    func next()
    func prev()
}
// Capabilities (checked by conformance in the UI)
@MainActor public protocol AppearanceConfigurable { func apply(settings: ReaderSettings) }
@MainActor public protocol TextSelectable: AnyObject { func deselect() }   // selection reported via delegate
@MainActor public protocol RangeAnnotatable: AnyObject {
    func addAnnotation(_ annotation: Annotation)
    func removeAnnotation(_ annotation: Annotation)   // was removeAnnotation(cfi:)
}
@MainActor public protocol Searchable: AnyObject {
    func search(query: String)
    func clearSearch()
}
// NavigatorDelegate: didTapAnnotation now reports the stored annotation's id (format-neutral),
// not an EPUB CFI string.
func navigator(didTapAnnotation id: UUID)     // replaces (didTapAnnotation cfi: String)

// Locator gains:
public var pageQuads: [[Double]]?             // PDF highlight quads in page space; nil otherwise
public var anchorKey: String { cfi ?? "page:\(spineIndex)" }   // format-neutral bookmark/position key
```

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IqraReaderTests/NavigatorProtocolsTests.swift
import XCTest
@testable import IqraReader

final class NavigatorProtocolsTests: XCTestCase {
    func testEPUBNavigatorConformsToAllCapabilities() {
        // Compile-time conformance is the assertion; a runtime check documents it.
        let type: Any.Type = EPUBNavigator.self
        XCTAssertTrue(type is Navigator.Type)
        XCTAssertTrue(type is (any TextSelectable.Type))
        XCTAssertTrue(type is (any RangeAnnotatable.Type))
        XCTAssertTrue(type is (any Searchable.Type))
        XCTAssertTrue(type is (any AppearanceConfigurable.Type))
    }

    func testLocatorAnchorKeyPrefersCFIElsePage() {
        XCTAssertEqual(Locator(spineIndex: 3, cfi: "epubcfi(/6/8)", totalProgression: 0.2).anchorKey,
                       "epubcfi(/6/8)")
        XCTAssertEqual(Locator(spineIndex: 7, cfi: nil, totalProgression: 0.5).anchorKey, "page:7")
    }

    func testLocatorPageQuadsRoundTripAndLegacyDecode() throws {
        let loc = Locator(spineIndex: 4, cfi: nil, totalProgression: 0.3,
                          pageQuads: [[0, 0, 10, 0, 0, 8, 10, 8]])
        XCTAssertEqual(try Locator.from(jsonData: loc.jsonData()), loc)
        // legacy locator with no pageQuads key decodes to nil
        let legacy = try Locator.from(jsonData: Data(#"{"spineIndex":1,"totalProgression":0.1}"#.utf8))
        XCTAssertNil(legacy.pageQuads)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NavigatorProtocolsTests`
Expected: FAIL — `Navigator`/`anchorKey`/`pageQuads` unknown.

- [ ] **Step 3: Implement the protocols + Locator additions**

Replace `Sources/IqraReader/NavigatorProtocols.swift`:

```swift
// Sources/IqraReader/NavigatorProtocols.swift
import Foundation

/// Base navigator surface (spec: protocol composition). Every format's navigator conforms;
/// capability protocols below are adopted only by navigators that support them, and the UI
/// drives features by conformance check — so it can never offer text highlighting on a comic.
@MainActor public protocol Navigator: AnyObject {
    var delegate: NavigatorDelegate? { get set }
    func start()
    func goTo(locator: Locator)
    func next()
    func prev()
}

@MainActor public protocol AppearanceConfigurable {
    func apply(settings: ReaderSettings)
}

/// Text can be selected; selections are reported via `NavigatorDelegate.navigator(didChangeSelection:)`.
@MainActor public protocol TextSelectable: AnyObject {
    func deselect()
}

/// Range highlights/notes can be drawn; taps are reported via `NavigatorDelegate.navigator(didTapAnnotation:)`.
@MainActor public protocol RangeAnnotatable: AnyObject {
    func addAnnotation(_ annotation: Annotation)
    func removeAnnotation(_ annotation: Annotation)
}

/// Full-text search within the open document; hits via `NavigatorDelegate`.
@MainActor public protocol Searchable: AnyObject {
    func search(query: String)
    func clearSearch()
}

@MainActor public protocol NavigatorDelegate: AnyObject {
    func navigatorDidLoad(title: String?, toc: [TOCItem])
    func navigator(didRelocate locator: Locator)
    func navigator(didFail message: String)
    func navigator(didChangeSelection selection: SelectionInfo?)
    func navigator(didTapAnnotation id: UUID)
    func navigator(didFindSearchHit hit: SearchHit)
    func navigatorDidFinishSearch()
}

public extension NavigatorDelegate {
    func navigator(didChangeSelection selection: SelectionInfo?) {}
    func navigator(didTapAnnotation id: UUID) {}
    func navigator(didFindSearchHit hit: SearchHit) {}
    func navigatorDidFinishSearch() {}
}

public struct TOCItem: Codable, Equatable, Sendable {
    public let label: String
    public let href: String?
    public let subitems: [TOCItem]?
    public init(label: String, href: String?, subitems: [TOCItem]?) {
        self.label = label; self.href = href; self.subitems = subitems
    }
}
```

In `Sources/IqraReader/Locator.swift`, add to `Locator`'s stored properties + init (trailing, default nil so legacy JSON and existing call sites both work):

```swift
    public var pageQuads: [[Double]]?   // PDF highlight quads (page space), each [x0,y0,x1,y1,x2,y2,x3,y3]
```
(add `pageQuads: [[Double]]? = nil` to `init`, assign it). Then add the computed key (not stored → not Codable):

```swift
public extension Locator {
    /// Format-neutral identity for "same position" (bookmark dedupe, goTo). EPUB uses the CFI;
    /// PDF/comics have no CFI and use the page index.
    var anchorKey: String { cfi ?? "page:\(spineIndex)" }
}
```

- [ ] **Step 4: Conform EPUBNavigator + carry the annotation id**

In `Sources/IqraReader/EPUBNavigator.swift`:
- Add conformances: `extension EPUBNavigator: Navigator {}` is already partly there via existing methods; explicitly declare `public final class EPUBNavigator: NSObject, Navigator, AppearanceConfigurable, TextSelectable, RangeAnnotatable, Searchable`.
- Add `public func goTo(locator: Locator) { if let cfi = locator.cfi { goTo(cfi: cfi) } else { goTo(fraction: locator.totalProgression) } }` (keep the existing `goTo(cfi:)`/`goTo(fraction:)` as the routed-to helpers).
- Change `removeAnnotation(cfi:)` → `public func removeAnnotation(_ annotation: Annotation)`; inside, `guard let cfi = annotation.locator.cfi else { return }` then the existing `iqra.removeAnnotation({cfi})` call.
- `addAnnotation(_ annotation: Annotation)`: include the id in the payload — `["cfi": ..., "color": ..., "kind": ..., "id": annotation.id.uuidString]`.
- In `handle(message:)`, change the `"annotationTapped"` case to read `dict["id"]` as a UUID string → `delegate?.navigator(didTapAnnotation: uuid)`. Keep a fallback: if no id, resolve nothing (return).

In `Sources/IqraReader/ReaderAssets/bridge.js`:
- In the `addAnnotation` command, store the id on the registry entry: `annotations.set(a.cfi, { value: a.cfi, color: a.color, kind: a.kind, id: a.id })`, and pass the same object to `view.addAnnotation`.
- In the `show-annotation` listener, look up the entry and post the id: `const e = annotations.get(value); post({ type: 'annotationTapped', id: e?.id ?? null, value })`.

- [ ] **Step 5: Update the M3 tap test + ReaderViewModel to the new tap signature**

In `Tests/IqraReaderTests/EPUBNavigatorAnnotationTests.swift`, `testAddAnnotationDrawsAndTapReportsCFI`: the recorder now records `didTapAnnotation id: UUID`; add the annotation with a known `let id = UUID()` (via a real `Annotation`), and after `view.showAnnotation({value: cfi})` assert `rec.tapped.last == id`. (The annotation must be added through `nav.addAnnotation(Annotation(id: id, …, cfi: annotationCFI, …))` so the bridge registry carries the id.) Rename the test `testAddAnnotationDrawsAndTapReportsID`.

In `App/Sources/ReaderViewModel.swift`:
- `navigator(didTapAnnotation id: UUID) { activeAnnotation = annotations.first { $0.id == id } }`.
- `deleteAnnotation`: `navigator.removeAnnotation(annotation)` instead of `removeAnnotation(cfi:)`.
- The `AnnRecorder`/delegate conformances update to the new signature.

- [ ] **Step 6: Run tests + build**

Run: `swift test`
Expected: PASS — NavigatorProtocolsTests + all M3 EPUB tests (annotation/search/appearance) still green. The tap test now asserts the id.

Run: `cd App && xcodegen generate && cd .. && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED, zero warnings.

- [ ] **Step 7: Commit**

```bash
git add Sources/IqraReader Tests/IqraReaderTests App/Sources/ReaderViewModel.swift
git commit -m "refactor: split navigator into base + capability protocols; report taps by annotation id"
```

---

### Task 2: Format-neutral ReaderViewModel + NavigatorFactory

**Files:**
- Create: `App/Sources/NavigatorFactory.swift`
- Modify: `App/Sources/ReaderViewModel.swift`
- Test: none (app target; the EPUB path is exercised by the existing package tests + build)

**Interfaces:**
- Consumes: `Navigator` + capability protocols (Task 1), `Locator.anchorKey`.
- Produces:

```swift
enum NavigatorFactory {
    /// Builds the right navigator for a format. Returns nil for formats with no reader yet.
    @MainActor static func make(formatType: FormatType, bookID: UUID, formatURL: URL,
                                initialLocator: Locator?, settings: ReaderSettings) -> (any Navigator)?
}
// ReaderViewModel changes: `navigator: any Navigator`; capability-gated intents; anchorKey bookmarks.
```

- [ ] **Step 1: NavigatorFactory (EPUB only for now; PDF/comic added in later tasks)**

```swift
// App/Sources/NavigatorFactory.swift
import Foundation
import IqraCore
import IqraReader

enum NavigatorFactory {
    @MainActor static func make(formatType: FormatType, bookID: UUID, formatURL: URL,
                                initialLocator: Locator?, settings: ReaderSettings) -> (any Navigator)? {
        switch formatType {
        case .epub, .mobi:   // MOBI renders through the same foliate engine (M5); EPUB today
            return EPUBNavigator(bookID: bookID, bookFileURL: formatURL,
                                 initialLocator: initialLocator, settings: settings)
        // .pdf and .cbz cases are added by Tasks 6 and 9.
        default:
            return nil
        }
    }
}
```

- [ ] **Step 2: Make ReaderViewModel hold `any Navigator` and drive capabilities by conformance**

Change `let navigator: EPUBNavigator` → `let navigator: any Navigator`. Build it via the factory in `init?`:

```swift
        let type: FormatType = ...   // from openableFormat
        guard let navigator = NavigatorFactory.make(
            formatType: type, bookID: bookID,
            formatURL: paths.formatFile(bookID: bookID, formatID: formatUUID, type: type),
            initialLocator: initial, settings: ReaderSettingsStore.load()) else { return nil }
        self.navigator = navigator
```

Change `openableFormat` (LibraryStore) to accept epub OR pdf OR cbz (Task covered in Phase B/C; for Task 2 keep it epub-only and note that PDF/comic tasks widen it). For Task 2, if `openableFormat` still returns epub-only, PDF/comic books simply won't open yet — that's fine, this task only proves the EPUB path survives the neutralization.

Capability-gate every intent that isn't on the base protocol:
- `settings.didSet`: `(navigator as? AppearanceConfigurable)?.apply(settings: settings)`.
- `pushAnnotationsToReader`: `(navigator as? RangeAnnotatable)?.addAnnotation(a)`.
- `createHighlight`/`changeColor`: `(navigator as? RangeAnnotatable)?.addAnnotation(updated)`.
- `deleteAnnotation`: `(navigator as? RangeAnnotatable)?.removeAnnotation(annotation)`.
- `clearSelection`: `(navigator as? TextSelectable)?.deselect()`.
- `runSearch`/`clearSearch`: `(navigator as? Searchable)?.search(query:)` / `.clearSearch()`.
- `goToHit`: `navigator.goTo(locator: Locator(spineIndex: 0, cfi: hit.cfi, totalProgression: 0))` — for PDF hits, `SearchHit.cfi` will instead carry a page-locator string (Task 4 defines PDF hits with a locator); simplest: give `SearchHit` an optional `locator: Locator` OR keep navigating by the hit's own coordinate. **Decision:** add `public var locator: Locator` to `SearchHit` (Task 4) and navigate via `navigator.goTo(locator: hit.locator)`. For Task 2 (EPUB only) build the locator from the cfi. Note this cross-task dependency in the plan.
- `goTo(_ annotation:)`: `navigator.goTo(locator: annotation.locator)`.

Make bookmark/tap identity format-neutral:
- `isCurrentPositionBookmarked`: compare `anchorKey`, not `cfi`: `guard let key = lastLocator?.anchorKey ...; annotations.contains { $0.kind == .bookmark && $0.locator.anchorKey == key }`.
- `bookmarkedAnnotation(at key: String)`: match `$0.locator.anchorKey == key`.
- `toggleBookmarkAtCurrentPosition`: use `lastLocator.anchorKey`.
- `didTapAnnotation id:` already resolves by id (Task 1).
- Expose capability flags for the UI (so ReaderScreen shows/hides chrome): `var canSelectText: Bool { navigator is TextSelectable }`, `var canSearch: Bool { navigator is Searchable }`, `var canConfigureAppearance: Bool { navigator is AppearanceConfigurable }`.

- [ ] **Step 3: Build + verify EPUB unaffected**

Run: `swift test && cd App && xcodegen generate && cd .. && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build`
Expected: PASS + BUILD SUCCEEDED. The EPUB reader behaves exactly as M3 (the smoke path is unchanged; only the plumbing is now protocol-driven).

- [ ] **Step 4: Commit**

```bash
git add App/Sources
git commit -m "refactor: format-neutral ReaderViewModel driving navigators by capability"
```

---

## Phase B — PDF (PDFKit)

### Task 3: PDFNavigator core (load, position, TOC, navigation)

**Files:**
- Create: `Sources/IqraReader/PDFNavigator.swift`, `Tests/IqraReaderTests/Support/PDFFixtures.swift`
- Test: `Tests/IqraReaderTests/PDFNavigatorTests.swift`

**Interfaces:**
- Consumes: `Navigator`/`NavigatorDelegate`/`TOCItem`/`Locator` (Task 1), PDFKit.
- Produces:

```swift
@MainActor public final class PDFNavigator: NSObject, Navigator {
    public let pdfView: PDFView
    public weak var delegate: NavigatorDelegate?
    public init?(bookID: UUID, bookFileURL: URL, initialLocator: Locator?)
    public func start()
    public func goTo(locator: Locator)
    public func next(); public func prev()
    public var pageCount: Int
    public static func pageLocator(pageIndex: Int, pageCount: Int, tocLabel: String?) -> Locator
    public static func toc(from document: PDFDocument) -> [TOCItem]   // pure, testable
}
```

- [ ] **Step 1: PDF fixture builder + failing test**

```swift
// Tests/IqraReaderTests/Support/PDFFixtures.swift
import Foundation
import CoreGraphics
import CoreText

enum PDFFixtures {
    /// A PDF with `pageCount` pages; page i contains the text `texts[i]` (drawn) so search
    /// and text extraction have something to find. No outline (CGPDFContext can't add one).
    static func makePDF(pageCount: Int, texts: [String] = [], dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 600)
        let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        for i in 0..<pageCount {
            ctx.beginPDFPage(nil)
            let text = i < texts.count ? texts[i] : "Page \(i)"
            let attr = NSAttributedString(string: text,
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 24, nil)])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 40, y: 500)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
```

```swift
// Tests/IqraReaderTests/PDFNavigatorTests.swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PDFNavigatorTests`
Expected: FAIL — `PDFNavigator` unknown.

- [ ] **Step 3: Implement PDFNavigator**

```swift
// Sources/IqraReader/PDFNavigator.swift
import Foundation
import PDFKit

/// PDFKit-backed navigator. The app hosts `pdfView` in a representable; all durable state
/// (position, annotations) is the caller's responsibility — the navigator reports position
/// via the delegate and never mutates the source file.
@MainActor public final class PDFNavigator: NSObject, Navigator {
    public let pdfView = PDFView()
    public weak var delegate: NavigatorDelegate?

    private let document: PDFDocument
    private let initialLocator: Locator?
    private var pageObserver: NSObjectProtocol?

    public var pageCount: Int { document.pageCount }

    public init?(bookID: UUID, bookFileURL: URL, initialLocator: Locator?) {
        guard let doc = PDFDocument(url: bookFileURL), doc.pageCount > 0 else { return nil }
        self.document = doc
        self.initialLocator = initialLocator
        super.init()
    }

    public func start() {
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .horizontal
        pdfView.pageShadowsEnabled = true

        delegate?.navigatorDidLoad(title: document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                                   toc: Self.toc(from: document))

        // Restore to the saved page after layout (setting document doesn't lay out synchronously).
        let restoreIndex = initialLocator.map { min(max(0, $0.spineIndex), document.pageCount - 1) }
        Task { @MainActor in
            if let idx = restoreIndex, let page = document.page(at: idx) { pdfView.go(to: page) }
            self.emitRelocate()
        }
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.emitRelocate() }
        }
    }

    public func goTo(locator: Locator) {
        let idx = min(max(0, locator.spineIndex), document.pageCount - 1)
        if let page = document.page(at: idx) { pdfView.go(to: page) }
    }

    public func next() { pdfView.goToNextPage(nil) }
    public func prev() { pdfView.goToPreviousPage(nil) }

    private func emitRelocate() {
        guard let current = pdfView.currentPage else { return }
        let idx = document.index(for: current)
        delegate?.navigator(didRelocate: Self.pageLocator(pageIndex: idx, pageCount: document.pageCount,
                                                          tocLabel: nil))
    }

    public static func pageLocator(pageIndex: Int, pageCount: Int, tocLabel: String?) -> Locator {
        let denom = Double(max(1, pageCount - 1))
        return Locator(spineIndex: pageIndex, cfi: nil,
                       totalProgression: Double(pageIndex) / denom, tocLabel: tocLabel)
    }

    /// Flatten the PDF outline into our TOCItem tree. `href` carries the destination page index
    /// as a string so the app can navigate via goTo(locator:).
    public static func toc(from document: PDFDocument) -> [TOCItem] {
        guard let root = document.outlineRoot else { return [] }
        func children(of node: PDFOutline) -> [TOCItem] {
            (0..<node.numberOfChildren).compactMap { i -> TOCItem? in
                guard let c = node.child(at: i) else { return nil }
                let dest = c.destination ?? (c.action as? PDFActionGoTo)?.destination
                let pageIndex = dest?.page.map { document.index(for: $0) }
                let subs = children(of: c)
                return TOCItem(label: c.label ?? "", href: pageIndex.map(String.init),
                               subitems: subs.isEmpty ? nil : subs)
            }
        }
        return children(of: root)
    }

    deinit { if let o = pageObserver { NotificationCenter.default.removeObserver(o) } }
}
```

- [ ] **Step 4: Run tests + full suite**

Run: `swift test --filter PDFNavigatorTests && swift test`
Expected: PASS. (PDFView instantiates headlessly on the macOS test host; if the relocate test proves flaky like the WebKit ones, use deterministic waits and report DONE_WITH_CONCERNS with exact output — never silent-skip.)

- [ ] **Step 5: Commit**

```bash
git add Sources/IqraReader/PDFNavigator.swift Tests/IqraReaderTests
git commit -m "feat: PDFKit navigator with page position, restore, and outline TOC"
```

---

### Task 4: PDF search (Searchable)

**Files:**
- Modify: `Sources/IqraReader/PDFNavigator.swift` (conform `Searchable`), `Sources/IqraReader/Locator.swift` (add `SearchHit.locator`), `Sources/IqraReader/EPUBNavigator.swift` (populate `SearchHit.locator` from cfi)
- Test: `Tests/IqraReaderTests/PDFSearchTests.swift`

**Interfaces:**
- Consumes: `PDFDocument.findString`, `Searchable`, `SearchHit`.
- Produces: `SearchHit` gains `public var locator: Locator` (so the UI navigates any hit uniformly); `PDFNavigator.search(query:)`/`clearSearch()`.

- [ ] **Step 1: Add SearchHit.locator + failing test**

Add `public var locator: Locator` to `SearchHit` (in `Locator.swift`), with it in the init (default a page-0 locator is NOT ok — make it required). Update the EPUB search-hit construction in `EPUBNavigator.handle(message:)` `"searchHit"` case to build `Locator(spineIndex: 0, cfi: cfi, totalProgression: 0)`. `SearchHit.id` stays `cfi`.

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PDFSearchTests`
Expected: FAIL — `PDFNavigator` doesn't conform to `Searchable` / no `SearchHit.locator`.

- [ ] **Step 3: Implement search on PDFNavigator**

```swift
extension PDFNavigator: Searchable {
    public func search(query: String) {
        clearSearch()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { delegate?.navigatorDidFinishSearch(); return }
        // Synchronous findString is fine for reader-sized PDFs; run off the current runloop tick
        // so the caller (UI) isn't blocked, and to mirror the async feel of the EPUB search.
        Task { @MainActor in
            let selections = document.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
            var drawn: [PDFSelection] = []
            for sel in selections {
                guard let page = sel.pages.first else { continue }
                let idx = document.index(for: page)
                let match = sel.string ?? q
                let excerpt = Self.excerpt(around: sel, on: page, match: match)
                sel.color = .yellow; drawn.append(sel)
                delegate?.navigator(didFindSearchHit: SearchHit(
                    cfi: "pdf:\(idx):\(sel.string ?? "")",   // stable-ish id for the list
                    excerptPre: excerpt.pre, excerptMatch: match, excerptPost: excerpt.post,
                    sectionLabel: nil,
                    locator: Self.pageLocator(pageIndex: idx, pageCount: document.pageCount, tocLabel: nil)))
            }
            pdfView.highlightedSelections = drawn.isEmpty ? nil : drawn
            delegate?.navigatorDidFinishSearch()
        }
    }

    public func clearSearch() { pdfView.highlightedSelections = nil }

    /// ~40 chars of page text on either side of the match for the results list.
    private static func excerpt(around selection: PDFSelection, on page: PDFPage,
                                match: String) -> (pre: String, post: String) {
        guard let pageText = page.string, let r = pageText.range(of: match) else { return ("", "") }
        let preStart = pageText.index(r.lowerBound, offsetBy: -40, limitedBy: pageText.startIndex) ?? pageText.startIndex
        let postEnd = pageText.index(r.upperBound, offsetBy: 40, limitedBy: pageText.endIndex) ?? pageText.endIndex
        return (String(pageText[preStart..<r.lowerBound]), String(pageText[r.upperBound..<postEnd]))
    }
}
```

- [ ] **Step 4: Run tests + full suite (EPUB search regression)**

Run: `swift test`
Expected: PASS — PDF search + the M3 EPUB search tests (now `SearchHit.locator` is populated from the cfi).

- [ ] **Step 5: Commit**

```bash
git add Sources/IqraReader Tests/IqraReaderTests
git commit -m "feat: PDF in-document search with page-locator hits and excerpts"
```

---

### Task 5: PDF highlights (TextSelectable + RangeAnnotatable)

**Files:**
- Create: `Sources/IqraReader/PDFAnnotationMapping.swift`
- Modify: `Sources/IqraReader/PDFNavigator.swift` (conform TextSelectable + RangeAnnotatable + AppearanceConfigurable; selection reporting, draw/remove/tap)
- Test: `Tests/IqraReaderTests/PDFAnnotationMappingTests.swift`

**Interfaces:**
- Consumes: `PDFSelection`, `PDFAnnotation`, `Annotation`, `Locator.pageQuads` (Task 1).
- Produces:

```swift
// Pure, testable mapping between PDFKit selections/quads and our Locator anchor.
public enum PDFAnnotationMapping {
    // page-space rect ↔ quad [x0,y0,x1,y1,x2,y2,x3,y3] (UL,UR,LL,LR)
    public static func quad(from rect: CGRect) -> [Double]
    public static func rect(from quad: [Double]) -> CGRect
    /// Build the anchor for a selection: page index, per-line quads (page space), and the text.
    public static func anchor(from selection: PDFSelection, in document: PDFDocument)
        -> (pageIndex: Int, quads: [[Double]], textQuote: String)?
    /// One `.highlight` PDFAnnotation per quad (Pattern A: bounds = quad rect, no explicit quadPoints).
    public static func highlightAnnotations(quads: [[Double]], colorHex: String) -> [PDFAnnotation]
}
// PDFNavigator: TextSelectable (deselect + selection reporting), RangeAnnotatable (draw/remove),
// tap hit-test → delegate.navigator(didTapAnnotation: id), AppearanceConfigurable (background/dark).
```

- [ ] **Step 1: Write the failing test (pure mapping)**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PDFAnnotationMappingTests`
Expected: FAIL — `PDFAnnotationMapping` unknown.

- [ ] **Step 3: Implement the pure mapping**

```swift
// Sources/IqraReader/PDFAnnotationMapping.swift
import Foundation
import PDFKit
#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformColor = UIColor
#endif

/// Pure conversions between PDFKit selections/annotations and our stored anchor
/// `{pageIndex, quads (page space), textQuote}`. No view, no I/O — fully unit-testable.
public enum PDFAnnotationMapping {
    /// Page-space rect → quad corners in Z order (UL, UR, LL, LR), page-space absolute.
    public static func quad(from r: CGRect) -> [Double] {
        [Double(r.minX), Double(r.maxY),   // UL
         Double(r.maxX), Double(r.maxY),   // UR
         Double(r.minX), Double(r.minY),   // LL
         Double(r.maxX), Double(r.minY)]   // LR
    }

    public static func rect(from quad: [Double]) -> CGRect {
        guard quad.count == 8 else { return .zero }
        let xs = [quad[0], quad[2], quad[4], quad[6]]
        let ys = [quad[1], quad[3], quad[5], quad[7]]
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func anchor(from selection: PDFSelection, in document: PDFDocument)
        -> (pageIndex: Int, quads: [[Double]], textQuote: String)? {
        let lines = selection.selectionsByLine()
        guard let page = (lines.first ?? selection).pages.first else { return nil }
        let quads = lines.map { quad(from: $0.bounds(for: page)) }.filter { $0.count == 8 }
        guard !quads.isEmpty else { return nil }
        return (document.index(for: page), quads, selection.string ?? "")
    }

    public static func highlightAnnotations(quads: [[Double]], colorHex: String) -> [PDFAnnotation] {
        let color = PlatformColor(hex: colorHex)
        return quads.map { q in
            let a = PDFAnnotation(bounds: rect(from: q), forType: .highlight, withProperties: nil)
            a.color = color
            return a
        }
    }
}

extension PlatformColor {
    convenience init(hex: String) {
        var v: UInt64 = 0; Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
```

- [ ] **Step 4: Implement the view-bound annotation methods on PDFNavigator**

Add to `PDFNavigator` (conform `TextSelectable, RangeAnnotatable, AppearanceConfigurable`). Selection reporting via `.PDFViewSelectionChanged`; keep an id↔PDFAnnotation registry for tap resolution:

```swift
    // add stored properties:
    private var pdfAnnotationsByID: [UUID: [PDFAnnotation]] = [:]
    private var selectionObserver: NSObjectProtocol?

    // in start(), after setting the document, observe selection:
    selectionObserver = NotificationCenter.default.addObserver(
        forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.emitSelection() }
    }
    // and re-draw stored highlights: the app calls addAnnotation for each on load (like EPUB).

    private func emitSelection() {
        guard let sel = pdfView.currentSelection, !(sel.string ?? "").isEmpty,
              let anchor = PDFAnnotationMapping.anchor(from: sel, in: document),
              let page = sel.pages.first else { delegate?.navigator(didChangeSelection: nil); return }
        // rect for the popover: union of line bounds → view space
        let pageRect = sel.bounds(for: page)
        let viewRect = pdfView.convert(pageRect, from: page)
        let locator = Locator(spineIndex: anchor.pageIndex, cfi: nil,
                              totalProgression: Self.pageLocator(pageIndex: anchor.pageIndex,
                                  pageCount: document.pageCount, tocLabel: nil).totalProgression,
                              textContext: TextContext(before: "", highlight: anchor.textQuote, after: ""),
                              pageQuads: anchor.quads)
        delegate?.navigator(didChangeSelection: SelectionInfo(
            text: anchor.textQuote, cfi: "", rect: SelectionRect(x: Double(viewRect.minX), y: Double(viewRect.minY),
                width: Double(viewRect.width), height: Double(viewRect.height)),
            spineIndex: anchor.pageIndex, totalProgression: locator.totalProgression,
            textContext: TextContext(before: "", highlight: anchor.textQuote, after: ""),
            locator: locator))   // SelectionInfo gains `locator` — see note below
    }

extension PDFNavigator: TextSelectable {
    public func deselect() { pdfView.clearSelection() }
}
extension PDFNavigator: RangeAnnotatable {
    public func addAnnotation(_ annotation: Annotation) {
        removeAnnotation(annotation)   // idempotent redraw
        guard let quads = annotation.locator.pageQuads,
              let page = document.page(at: annotation.locator.spineIndex) else { return }
        let anns = PDFAnnotationMapping.highlightAnnotations(
            quads: quads, colorHex: annotation.color?.cssColor ?? "#F7D774")
        for a in anns { page.addAnnotation(a) }
        pdfAnnotationsByID[annotation.id] = anns
    }
    public func removeAnnotation(_ annotation: Annotation) {
        guard let anns = pdfAnnotationsByID.removeValue(forKey: annotation.id) else { return }
        for a in anns { a.page?.removeAnnotation(a) }
    }
}
extension PDFNavigator: AppearanceConfigurable {
    public func apply(settings: ReaderSettings) {
        pdfView.backgroundColor = PlatformColor(hex: settings.theme.background)
        // (Page inversion for a true dark PDF is a PDFPage.draw override — deferred; background only.)
    }
}
```

Two supporting changes this task must make:
1. `SelectionInfo` gains `public var locator: Locator` (so the app builds a highlight annotation from a PDF selection uniformly — the EPUB path fills it from its cfi/textContext in `EPUBNavigator.handle`). Update the EPUB `"selected"` case + M3 tests accordingly (they construct `SelectionInfo`; add the locator).
2. Tap hit-test: install a tap gesture on `pdfView` (`#if os(iOS)` `UITapGestureRecognizer`, `#else` an `NSClickGestureRecognizer`) whose handler does `page(for:nearest:)` → `convert(_:to:page)` → `page.annotation(at:)`; if the hit `PDFAnnotation` is one we drew, reverse-look-up its id via `pdfAnnotationsByID` and call `delegate?.navigator(didTapAnnotation: id)`.

The app's `createHighlight` (Task 6) will read `currentSelection.locator` (which carries `pageQuads` for PDF, `cfi`/`textContext` for EPUB) and persist it — so one `createHighlight` path serves both.

- [ ] **Step 5: Run the mapping tests + full suite**

Run: `swift test`
Expected: PASS — mapping unit tests + all prior (EPUB `SelectionInfo` now carries a locator; M3 selection test updated).

- [ ] **Step 6: Commit**

```bash
git add Sources/IqraReader Tests/IqraReaderTests
git commit -m "feat: PDF text-selection highlights with page-quad anchors and tap hit-test"
```

---

### Task 6: PDF reader UI (host + thumbnail scrubber + wiring)

**Files:**
- Create: `App/Sources/PDFReaderView.swift`
- Modify: `App/Sources/ReaderScreen.swift`, `App/Sources/ReaderViewModel.swift` (createHighlight uses `sel.locator`), `App/Sources/NavigatorFactory.swift` (.pdf), `Sources/IqraLibrary/Database/LibraryStore.swift` (`openableFormat` accepts pdf)
- Test: none (app target; build both platforms)

**Interfaces:**
- Consumes: `PDFNavigator` (Tasks 3–5), the M3 selection/annotation/search UI, `SelectionInfo.locator`.
- Produces: a working PDF reading experience reusing the M3 chrome via capability checks.

- [ ] **Step 1: `openableFormat` accepts pdf; NavigatorFactory builds PDFNavigator**

`LibraryStore.openableFormat`: change the `formatType = 'epub'` filter to `formatType IN ('epub','pdf')` (comics added in Task 9). Keep the `present = 1` and ordering.

In `NavigatorFactory.make`, add:
```swift
        case .pdf:
            return PDFNavigator(bookID: bookID, bookFileURL: formatURL, initialLocator: initialLocator)
```

- [ ] **Step 2: PDFReaderView**

```swift
// App/Sources/PDFReaderView.swift
import SwiftUI
import PDFKit

struct PDFReaderView: View {
    let navigator: PDFNavigator
    var body: some View {
        VStack(spacing: 0) {
            PDFViewContainer(pdfView: navigator.pdfView).ignoresSafeArea(edges: .bottom)
            PDFThumbnailContainer(pdfView: navigator.pdfView).frame(height: 64)
        }
    }
}

private struct PDFViewContainer {
    let pdfView: PDFView
}
private struct PDFThumbnailContainer {
    let pdfView: PDFView
    func makeThumb() -> PDFThumbnailView {
        let t = PDFThumbnailView(); t.pdfView = pdfView
        t.thumbnailSize = CGSize(width: 40, height: 56); t.layoutMode = .horizontal
        return t
    }
}

#if os(macOS)
extension PDFViewContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ v: PDFView, context: Context) {}
}
extension PDFThumbnailContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFThumbnailView { makeThumb() }
    func updateNSView(_ v: PDFThumbnailView, context: Context) {}
}
#else
extension PDFViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { pdfView }
    func updateUIView(_ v: PDFView, context: Context) {}
}
extension PDFThumbnailContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFThumbnailView { makeThumb() }
    func updateUIView(_ v: PDFThumbnailView, context: Context) {}
}
#endif
```

- [ ] **Step 3: ReaderScreen hosts the right reader by navigator kind + capability-gates chrome**

In `ReaderScreen.swift`, replace the single `WebViewContainer(webView: model.navigator.webView)` with a type switch:

```swift
    @ViewBuilder private var readerSurface: some View {
        if let epub = model.navigator as? EPUBNavigator {
            WebViewContainer(webView: epub.webView)
        } else if let pdf = model.navigator as? PDFNavigator {
            PDFReaderView(navigator: pdf)
        } else {
            ContentUnavailableView("Unsupported", systemImage: "book.closed")
        }
    }
```

Capability-gate the toolbar buttons using the VM flags from Task 2:
- Appearance button: `if model.canConfigureAppearance { … }`.
- Find button: `if model.canSearch { … }`.
- The selection color bar, note editor, annotations list, and bookmark button stay — they work for any `RangeAnnotatable`/base navigator. (PDF is `RangeAnnotatable` + `TextSelectable`, so selection → highlight works; comics are neither, so the selection overlay simply never appears because `currentSelection` stays nil.)
- macOS arrow-key paging (`onKeyPress`) already calls `model.navigator.next()/prev()` — now on the base protocol, works for PDF too.

- [ ] **Step 4: createHighlight uses the selection's locator**

In `ReaderViewModel.createHighlight`, replace the hand-built EPUB locator with the selection's own (now format-neutral) locator:
```swift
    func createHighlight(color: HighlightColor) {
        guard let sel = currentSelection else { return }
        let annotation = Annotation(id: UUID(), kind: .highlight, locator: sel.locator, color: color,
                                    note: nil, createdAt: Date(), modifiedAt: Date())
        do { try persist(annotation); (navigator as? RangeAnnotatable)?.addAnnotation(annotation) }
        catch { readerError = "Couldn't save highlight: \(error)" }
        clearSelection()
    }
```
(`sel.locator` carries `cfi`+`textContext` for EPUB and `spineIndex`+`pageQuads`+`textQuote` for PDF — one path, both formats.)

- [ ] **Step 5: Build both platforms**

Run: `swift test && cd App && xcodegen generate && cd .. && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'generic/platform=iOS Simulator' build`
Expected: PASS + BUILD SUCCEEDED both, zero warnings.

- [ ] **Step 6: Commit**

```bash
git add App Sources/IqraLibrary/Database/LibraryStore.swift
git commit -m "feat: PDF reader UI with thumbnail scrubber, reusing the shared annotation/search chrome"
```

---

## Phase C — Comics (CBZ)

### Task 7: Comic extraction pipeline (CBZ → cache + manifest) + first-class import

**Files:**
- Create: `Sources/IqraReader/Comic/ComicManifest.swift`, `Sources/IqraReader/Comic/ComicExtractor.swift`, `Sources/IqraLibrary/Import/ComicMetadataExtractor.swift`
- Modify: `Sources/IqraLibrary/LibraryPaths.swift` (comic cache dir), `Sources/IqraLibrary/Import/ImportPipeline.swift` (cbz first-class)
- Test: `Tests/IqraReaderTests/ComicExtractorTests.swift`, `Tests/IqraLibraryTests/ComicImportTests.swift`

**Interfaces:**
- Consumes: ZIPFoundation, `LibraryPaths.Caches`.
- Produces:

```swift
// Sources/IqraReader/Comic/ComicManifest.swift
public struct ComicManifest: Codable, Equatable, Sendable {
    public struct Page: Codable, Equatable, Sendable { public let index: Int; public let fileName: String }
    public var pageCount: Int
    public var pages: [Page]
    public var readingDirection: String   // "ltr" | "rtl"
}
public enum ComicExtractor {
    /// Extract a CBZ's images (natural-sorted) into `cacheDir` as 0000.<ext>… + manifest.json.
    /// Returns the manifest. Idempotent-ish: re-extracts if the manifest/pages are missing.
    public static func extractCBZ(cbzURL: URL, into cacheDir: URL) throws -> ComicManifest
    public static func loadManifest(from cacheDir: URL) -> ComicManifest?
    static func isImage(_ path: String) -> Bool
}
// LibraryPaths.Caches gains: func comicPagesDir(formatID: UUID) -> URL
// ComicMetadataExtractor (IqraLibrary): ComicInfo.xml title + first-image cover, native.
```

- [ ] **Step 1: Write the failing extractor test**

```swift
// Tests/IqraReaderTests/ComicExtractorTests.swift
import XCTest
import ZIPFoundation
@testable import IqraReader

final class ComicExtractorTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A CBZ whose entries are deliberately out of lexicographic order (page 10 before page 2).
    func makeCBZ(pageNames: [String]) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".cbz")
        let a = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        try a.addEntry(with: "ComicInfo.xml", type: .file, uncompressedSize: 10,
                       provider: { p, s in Data("<ComicInfo/>".utf8).subdata(in: Int(p)..<Int(p)+s) })
        for name in pageNames {
            let bytes = Data([0xFF, 0xD8, 0xFF, UInt8(name.count)])  // fake jpeg-ish, distinct per page
            try a.addEntry(with: name, type: .file, uncompressedSize: Int64(bytes.count),
                           provider: { p, s in bytes.subdata(in: Int(p)..<Int(p)+s) })
        }
        return url
    }

    func testExtractSortsNaturallyAndWritesManifest() throws {
        let cbz = try makeCBZ(pageNames: ["page10.jpg", "page2.jpg", "page1.jpg", "cover.png"])
        let cache = dir.appendingPathComponent("cache")
        let manifest = try ComicExtractor.extractCBZ(cbzURL: cbz, into: cache)

        XCTAssertEqual(manifest.pageCount, 4)
        // natural order: cover.png? No — localizedStandardCompare sorts "cover" after digits? Assert the
        // page1 < page2 < page10 ordering holds and cover sorts by name; check the digit run specifically:
        let names = manifest.pages.map(\.fileName)
        XCTAssertEqual(names, ["0000.png", "0001.jpg", "0002.jpg", "0003.jpg"]) // re-indexed to sorted order
        // the page files exist on disk
        for p in manifest.pages {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: cache.appendingPathComponent(p.fileName).path))
        }
        // manifest reloads
        XCTAssertEqual(ComicExtractor.loadManifest(from: cache), manifest)
    }

    func testExcludesNonImagesAndJunk() throws {
        let cbz = try makeCBZ(pageNames: ["001.jpg", "__MACOSX/._001.jpg", ".DS_Store", "notes.txt"])
        let cache = dir.appendingPathComponent("cache")
        let manifest = try ComicExtractor.extractCBZ(cbzURL: cbz, into: cache)
        XCTAssertEqual(manifest.pageCount, 1)  // only 001.jpg
    }
}
```

Note on the ordering assertion: the extractor sorts the ORIGINAL names with `localizedStandardCompare` (so `cover.png`, `page1`, `page2`, `page10`), then re-writes them to zero-padded sorted indices `0000.<origExt>`… The test above asserts the re-indexed names reflect the sorted original order — the implementer computes the exact expected mapping from the sort (`cover.png`→0000.png if "cover" sorts first, else adjust). **The implementer must set the test's expected array to the actual `localizedStandardCompare` order of the input names** (compute it: "cover.png" vs "page1.jpg" — 'c' < 'p', so cover is index 0). The point of the test is the natural digit ordering of page1/2/10 and the re-index; fix the literal to match.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ComicExtractorTests`
Expected: FAIL — `ComicExtractor` unknown.

- [ ] **Step 3: Implement ComicManifest + ComicExtractor**

```swift
// Sources/IqraReader/Comic/ComicManifest.swift
import Foundation
public struct ComicManifest: Codable, Equatable, Sendable {
    public struct Page: Codable, Equatable, Sendable {
        public let index: Int; public let fileName: String
        public init(index: Int, fileName: String) { self.index = index; self.fileName = fileName }
    }
    public var pageCount: Int
    public var pages: [Page]
    public var readingDirection: String
    public init(pageCount: Int, pages: [Page], readingDirection: String) {
        self.pageCount = pageCount; self.pages = pages; self.readingDirection = readingDirection
    }
}
```

```swift
// Sources/IqraReader/Comic/ComicExtractor.swift
import Foundation
import ZIPFoundation

public enum ComicExtractor {
    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "heic", "avif"]

    static func isImage(_ path: String) -> Bool {
        let base = (path as NSString).lastPathComponent
        guard !base.hasPrefix("."), !path.hasPrefix("__MACOSX/") else { return false }
        return imageExts.contains((path as NSString).pathExtension.lowercased())
    }

    public static func extractCBZ(cbzURL: URL, into cacheDir: URL) throws -> ComicManifest {
        let fm = FileManager.default
        try? fm.removeItem(at: cacheDir)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let archive = try Archive(url: cbzURL, accessMode: .read, pathEncoding: nil)
        let imageEntries = archive.filter { $0.type == .file && isImage($0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var pages: [ComicManifest.Page] = []
        for (i, entry) in imageEntries.enumerated() {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            let fileName = String(format: "%04d.%@", i, ext)
            let dest = cacheDir.appendingPathComponent(fileName)
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            try data.write(to: dest)
            pages.append(.init(index: i, fileName: fileName))
        }
        let manifest = ComicManifest(pageCount: pages.count, pages: pages, readingDirection: "ltr")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: cacheDir.appendingPathComponent("manifest.json"), options: .atomic)
        return manifest
    }

    public static func loadManifest(from cacheDir: URL) -> ComicManifest? {
        guard let data = try? Data(contentsOf: cacheDir.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(ComicManifest.self, from: data)
    }
}
```

Add to `LibraryPaths.Caches` (IqraLibrary):
```swift
    public func comicPagesDir(formatID: UUID) -> URL {
        root.appendingPathComponent("comics", isDirectory: true)
            .appendingPathComponent(formatID.uuidString, isDirectory: true)
    }
```

- [ ] **Step 4: ComicMetadataExtractor + import pipeline makes cbz first-class**

```swift
// Sources/IqraLibrary/Import/ComicMetadataExtractor.swift
import Foundation
import ZIPFoundation

/// Native comic metadata: ComicInfo.xml <Title> (fallback: filename) + first sorted image as cover.
/// Lives in IqraLibrary — no reader import; a small self-contained container walk.
public enum ComicMetadataExtractor {
    public static func extract(fileURL: URL, formatType: FormatType) -> ExtractionResult {
        guard formatType == .cbz,   // cbr stays quarantined this milestone
              let archive = try? Archive(url: fileURL, accessMode: .read, pathEncoding: nil) else {
            return .rejected(.unsupportedFormat)
        }
        let images = archive.filter { $0.type == .file && isImage($0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !images.isEmpty else { return .rejected(.corruptContainer) }

        var title = fileURL.deletingPathExtension().lastPathComponent
        if let ci = archive["ComicInfo.xml"] {
            var data = Data(); _ = try? archive.extract(ci) { data.append($0) }
            if let t = ComicInfoParser.title(data) { title = t }
        }
        var cover = Data(); _ = try? archive.extract(images[0]) { cover.append($0) }
        let meta = ExtractedMetadata(title: title, titleSort: makeTitleSort(title, language: nil),
                                     language: nil, publisher: nil, bookDescription: nil,
                                     contributors: [], identifiers: [])
        return .extracted(meta, coverData: cover.isEmpty ? nil : cover)
    }
    static func isImage(_ p: String) -> Bool {
        let ext = (p as NSString).pathExtension.lowercased()
        return !p.hasPrefix("__MACOSX/") && !((p as NSString).lastPathComponent.hasPrefix("."))
            && ["jpg","jpeg","png","gif","webp","bmp","tiff","heic","avif"].contains(ext)
    }
}

enum ComicInfoParser {
    static func title(_ data: Data) -> String? {
        final class D: NSObject, XMLParserDelegate {
            var inTitle = false; var title: String?
            func parser(_ p: XMLParser, didStartElement n: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) { inTitle = (n == "Title") }
            func parser(_ p: XMLParser, foundCharacters s: String) { if inTitle { title = (title ?? "") + s } }
            func parser(_ p: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) { if n == "Title" { inTitle = false } }
        }
        let parser = XMLParser(data: data); let d = D(); parser.delegate = d; parser.parse()
        let t = d.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t : nil
    }
}
```

In `ImportPipeline.importFile`, extend the sniff/extract stage so `.cbz` is accepted (not quarantined) and routed to `ComicMetadataExtractor.extract`. The current code allows `formatType == .epub || formatType == .pdf`; add `|| formatType == .cbz`, and in the extraction switch call `ComicMetadataExtractor.extract` for `.cbz`. `.cbr` (and `.mobi`) continue to quarantine as `.unsupportedFormat`. Everything downstream (hash, dedupe, stage, thumbnail from cover, DB insert) is format-agnostic and unchanged. **Full page extraction is NOT done at import** — it happens lazily at first open (Task 8), so import stays fast.

- [ ] **Step 5: Write the import test + run**

```swift
// Tests/IqraLibraryTests/ComicImportTests.swift  — mirror ImportPipelineTests structure
    func testImportsCBZAsBookWithCover() throws {
        // build a minimal cbz fixture (zip with ComicInfo.xml + one jpeg-magic image)
        // import it; assert .imported, a book row exists with the ComicInfo/filename title,
        // the format is cbz, and cover.jpg (from the first image) is written.
    }
    func testCBRStillQuarantined() throws {
        // a file with "Rar!" magic → .quarantined(.unsupportedFormat)
    }
```
(The implementer writes the full fixtures mirroring `EPUBMetadataExtractorTests`/`ImportPipelineTests`.)

Run: `swift test`
Expected: PASS — extractor + import tests, EPUB/PDF unaffected.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "feat: CBZ extraction to cache with manifest; comics as first-class imports"
```

---

### Task 8: ComicNavigator (page-based, base capabilities only)

**Files:**
- Create: `Sources/IqraReader/Comic/ComicNavigator.swift`
- Test: `Tests/IqraReaderTests/ComicNavigatorTests.swift`

**Interfaces:**
- Consumes: `Navigator`/`NavigatorDelegate` (Task 1), `ComicExtractor`/`ComicManifest` (Task 7).
- Produces:

```swift
@Observable @MainActor public final class ComicNavigator: Navigator {
    public struct PageRef: Identifiable, Equatable { public let index: Int; public let url: URL; public var id: Int { index } }
    public weak var delegate: NavigatorDelegate?
    public private(set) var pages: [PageRef]
    public var currentIndex: Int   // the view two-way-binds this; changes emit a relocate
    public private(set) var readingDirection: String
    public init(bookID: UUID, comicFileURL: URL, cacheDir: URL, initialLocator: Locator?)
    public func start()            // extract-if-needed, load manifest, emit load + restore
    public func goTo(locator: Locator)
    public func next(); public func prev()
}
```
ComicNavigator conforms to `Navigator` and NOTHING else — no `TextSelectable`/`Searchable`/`RangeAnnotatable`. This is the capability split's whole point: the UI's `canSearch`/`canSelectText` checks return false, so no text chrome ever appears for a comic. Bookmarks still work — they ride the base `Navigator`'s relocate/position, not a capability.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IqraReaderTests/ComicNavigatorTests.swift
import XCTest
import ZIPFoundation
@testable import IqraReader

final class ComicNavigatorTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    func makeCBZ(pages: Int) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".cbz")
        let a = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        for i in 0..<pages {
            let bytes = Data([0xFF, 0xD8, UInt8(i)])
            try a.addEntry(with: String(format: "%03d.jpg", i), type: .file,
                           uncompressedSize: Int64(bytes.count),
                           provider: { p, s in bytes.subdata(in: Int(p)..<Int(p)+s) })
        }
        return url
    }

    @MainActor
    func testStartExtractsLoadsAndRestores() async throws {
        let cbz = try makeCBZ(pages: 5)
        let cache = dir.appendingPathComponent("cache")
        let nav = ComicNavigator(bookID: UUID(), comicFileURL: cbz, cacheDir: cache,
                                 initialLocator: Locator(spineIndex: 3, cfi: nil, totalProgression: 0.75))
        let rec = ComicRecorder(); nav.delegate = rec
        let loaded = expectation(description: "loaded"); rec.onLoad = { loaded.fulfill() }
        nav.start()
        await fulfillment(of: [loaded], timeout: 10)
        XCTAssertEqual(nav.pages.count, 5)
        XCTAssertEqual(nav.currentIndex, 3)                        // restored
        XCTAssertTrue(FileManager.default.fileExists(atPath: nav.pages[0].url.path))
    }

    @MainActor
    func testPageChangeEmitsRelocate() async throws {
        let cbz = try makeCBZ(pages: 4)
        let nav = ComicNavigator(bookID: UUID(), comicFileURL: cbz,
                                 cacheDir: dir.appendingPathComponent("c"), initialLocator: nil)
        let rec = ComicRecorder(); nav.delegate = rec
        let loaded = expectation(description: "loaded"); rec.onLoad = { loaded.fulfill() }
        nav.start(); await fulfillment(of: [loaded], timeout: 10)

        nav.goTo(locator: Locator(spineIndex: 2, cfi: nil, totalProgression: 0))
        XCTAssertEqual(nav.currentIndex, 2)
        XCTAssertEqual(rec.locators.last?.spineIndex, 2)
        XCTAssertEqual(rec.locators.last?.totalProgression ?? 0, 2.0/3.0, accuracy: 0.001)
    }
}

@MainActor
final class ComicRecorder: NavigatorDelegate {
    var locators: [Locator] = []
    var onLoad: (() -> Void)?
    func navigatorDidLoad(title: String?, toc: [TOCItem]) { onLoad?() }
    func navigator(didRelocate locator: Locator) { locators.append(locator) }
    func navigator(didFail message: String) { XCTFail(message) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ComicNavigatorTests`
Expected: FAIL — `ComicNavigator` unknown.

- [ ] **Step 3: Implement ComicNavigator**

```swift
// Sources/IqraReader/Comic/ComicNavigator.swift
import Foundation
import Observation

@Observable @MainActor public final class ComicNavigator: Navigator {
    public struct PageRef: Identifiable, Equatable, Sendable {
        public let index: Int; public let url: URL; public var id: Int { index }
    }
    @ObservationIgnored public weak var delegate: NavigatorDelegate?
    public private(set) var pages: [PageRef] = []
    public private(set) var readingDirection: String = "ltr"
    public var currentIndex: Int = 0 {
        didSet { if currentIndex != oldValue { emitRelocate() } }
    }

    private let comicFileURL: URL
    private let cacheDir: URL
    private let initialLocator: Locator?
    private var pageCount: Int { pages.count }

    public init(bookID: UUID, comicFileURL: URL, cacheDir: URL, initialLocator: Locator?) {
        self.comicFileURL = comicFileURL; self.cacheDir = cacheDir; self.initialLocator = initialLocator
    }

    public func start() {
        let manifest: ComicManifest
        do {
            manifest = ComicExtractor.loadManifest(from: cacheDir)
                ?? (try ComicExtractor.extractCBZ(cbzURL: comicFileURL, into: cacheDir))
        } catch {
            delegate?.navigator(didFail: "Couldn't open comic: \(error)"); return
        }
        readingDirection = manifest.readingDirection
        pages = manifest.pages.map { PageRef(index: $0.index, url: cacheDir.appendingPathComponent($0.fileName)) }
        delegate?.navigatorDidLoad(title: comicFileURL.deletingPathExtension().lastPathComponent, toc: [])
        let restore = min(max(0, initialLocator?.spineIndex ?? 0), max(0, pages.count - 1))
        currentIndex = restore
        emitRelocate()   // ensure an initial position is persisted even if restore == 0 (didSet won't fire)
    }

    public func goTo(locator: Locator) {
        currentIndex = min(max(0, locator.spineIndex), max(0, pages.count - 1))
    }
    public func next() { if currentIndex < pages.count - 1 { currentIndex += 1 } }
    public func prev() { if currentIndex > 0 { currentIndex -= 1 } }

    private func emitRelocate() {
        guard !pages.isEmpty else { return }
        let denom = Double(max(1, pages.count - 1))
        delegate?.navigator(didRelocate: Locator(spineIndex: currentIndex, cfi: nil,
                                                 totalProgression: Double(currentIndex) / denom))
    }
}
```

- [ ] **Step 4: Run tests + full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/IqraReader/Comic/ComicNavigator.swift Tests/IqraReaderTests/ComicNavigatorTests.swift
git commit -m "feat: page-based comic navigator (base capabilities only)"
```

---

### Task 9: Comic reader UI (memory-windowed pager) + wiring

**Files:**
- Create: `App/Sources/ComicReaderView.swift`
- Modify: `App/Sources/ReaderScreen.swift`, `App/Sources/NavigatorFactory.swift`, `App/Sources/ReaderViewModel.swift` (pass the comic cache dir), `Sources/IqraLibrary/Database/LibraryStore.swift` (`openableFormat` accepts cbz)
- Test: none (app target; build both platforms)

**Interfaces:**
- Consumes: `ComicNavigator` (Task 8), `LibraryPaths.Caches.comicPagesDir`.
- Produces: a memory-safe comic reading experience; comics get position restore + bookmarks, no text chrome.

- [ ] **Step 1: openableFormat accepts cbz; factory builds ComicNavigator**

`LibraryStore.openableFormat`: widen the filter to `formatType IN ('epub','pdf','cbz')`.

`NavigatorFactory.make` needs the comic cache dir. Add a `caches: LibraryPaths.Caches` parameter to `make(...)` (thread it through from `ReaderViewModel.init?`, which already has `caches`? it has `paths`; add `caches`). Then:
```swift
        case .cbz:
            return ComicNavigator(bookID: bookID, comicFileURL: formatURL,
                                  cacheDir: caches.comicPagesDir(formatID: formatID), initialLocator: initialLocator)
```
(`ReaderViewModel.init?` must receive `caches` — `LibraryViewModel.readerModel(for:)` already has `caches` from M2; pass it in. `NavigatorFactory.make` gains `formatID` + `caches` params.)

- [ ] **Step 2: ComicReaderView (memory-windowed pager)**

```swift
// App/Sources/ComicReaderView.swift
import SwiftUI
import ImageIO
import IqraReader

struct ComicReaderView: View {
    @Bindable var navigator: ComicNavigator

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(navigator.pages) { page in
                    ComicPageCell(url: page.url)
                        .containerRelativeFrame(.horizontal)
                        .id(page.index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: Binding(
            get: { navigator.currentIndex },
            set: { if let i = $0 { navigator.currentIndex = i } }))
        .environment(\.layoutDirection, navigator.readingDirection == "rtl" ? .rightToLeft : .leftToRight)
        .background(.black)
        .ignoresSafeArea()
    }
}

/// Decodes its page lazily (downsampled, off-main) and releases on disappear — so only the
/// visible ±1 pages are ever held decoded, regardless of comic length.
private struct ComicPageCell: View {
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let cg = image {
                Image(decorative: cg, scale: 1, orientation: .up).resizable().scaledToFit()
            } else { Color.black }
        }
        .task(id: url) { image = await Task.detached { Self.downsample(url, maxPixel: 2048) }.value }
        .onDisappear { image = nil }
    }
    static func downsample(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
```

- [ ] **Step 3: Host in ReaderScreen**

Add the comic branch to `readerSurface`:
```swift
        } else if let comic = model.navigator as? ComicNavigator {
            ComicReaderView(navigator: comic)
```
Everything else is capability-gated already (search/appearance buttons hidden for comics; the selection color bar never shows because comics never post a selection; the bookmark button + annotations list work because bookmarks ride the base position). Confirm the annotations list still opens (it shows only bookmarks for a comic — no highlights exist).

- [ ] **Step 4: Build both platforms**

Run: `swift test && cd App && xcodegen generate && cd .. && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'generic/platform=iOS Simulator' build`
Expected: PASS + BUILD SUCCEEDED both, zero warnings.

- [ ] **Step 5: Commit**

```bash
git add App Sources/IqraLibrary/Database/LibraryStore.swift
git commit -m "feat: memory-windowed comic reader with position restore and bookmarks"
```

---

## Phase D — Final assembly

### Task 10: iOS build, docs, smoke checklist

**Files:**
- Modify: `CLAUDE.md`, `docs/superpowers/plans/2026-07-12-m1-followups.md`
- Test: build verification only

- [ ] **Step 1: Both-platform build + full suite**

Run:
```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build
xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'generic/platform=iOS Simulator' build
swift test
```
Expected: BUILD SUCCEEDED both; `swift test` green (the known M2 WKWebView full-run flake may need one rerun — note, don't chase; PDF/comic tests are WebKit-free and deterministic).

- [ ] **Step 2: Docs**

`CLAUDE.md`: update the architecture bullet — the reader now supports EPUB (foliate), **PDF (PDFKit: read/spread/TOC/search/text-highlights+notes/bookmarks)**, and **CBZ comics (paged image viewer, position, bookmarks)**; navigators conform to a base `Navigator` + capability protocols (`TextSelectable`/`RangeAnnotatable`/`Searchable`/`AppearanceConfigurable`), driven by conformance in the UI. CBR and MOBI still pending.

`docs/superpowers/plans/2026-07-12-m1-followups.md`: mark the **capability-protocol split DONE (M4)**; record CBR as the remaining comic format (needs `Unrar.swift` — non-OSI UnRAR license ack + sequential extraction; the format-agnostic viewer/cache/model make it a clean later add); note MOBI (M5) still open; note PDF dark-mode page inversion deferred (background-only for now).

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs
git commit -m "docs: M4 completion notes; CBR/MOBI/PDF-dark-mode deferred"
```

- [ ] **Step 4: Manual smoke test (human — agents skip, controller reports it owed)**

On macOS + iOS: import a **PDF** → it renders; page forward/back (arrows/swipe), thumbnail scrubber jumps pages, progress % updates; open the outline TOC → jump to a section; **Find** a word → results with excerpts → tap → navigates + the match highlights; **select text → color bar → highlight**; tap the highlight → note editor; annotations list shows it → tap → navigates back; quit + relaunch → position + highlights restored. Import a **CBZ** → pages render; swipe/arrow through them (memory stays flat on a long comic); bookmark a page, toggle off; quit + relaunch → page + bookmark restored. Confirm a comic shows **no** Find/Appearance/highlight chrome (capability-gated).

---

## Plan Self-Review Notes

- **Spec/scope coverage (M4):** capability-protocol split ✔ (Tasks 1–2, the spec's protocol composition, now real); PDF read + two-page spread + outline TOC ✔ (Task 3, `displayMode`/`displaysAsBook` available — spread is a display-mode toggle deferred to a settings control but the mode exists); PDF search ✔ (Task 4); PDF text highlights + notes with `{pageIndex, quads, textQuote}` anchors stored in DB, never mutating the file ✔ (Task 5); PDF bookmarks ✔ (base position + M3 bookmark UI); PDF reader UI + thumbnail scrubber ✔ (Task 6); comics extract-to-cache + manifest + natural sort ✔ (Task 7); comics first-class import ✔ (Task 7); memory-windowed pager + position + bookmarks ✔ (Tasks 8–9); page-based `Locator` with no schema change ✔ (Task 1, `spineIndex` reused). Deferred and recorded: CBR (Unrar/license), MOBI (M5), PDF dark-mode page inversion, PDF two-page-spread settings toggle (mode exists; UI control is polish).
- **Boundary check:** `IqraReader` gains PDFKit (allowed system framework) + comic code, never imports IqraLibrary ✔; `ComicMetadataExtractor` lives in IqraLibrary and imports no reader code (self-contained ZIP walk) ✔; annotation/reading-state locators stay opaque JSON to IqraLibrary ✔.
- **Type consistency:** `SearchHit.locator` added in Task 4 and consumed by `ReaderViewModel.goToHit` (Task 2 noted the dependency) ✔; `SelectionInfo.locator` added in Task 5 and consumed by `createHighlight` (Task 6) ✔; `didTapAnnotation id: UUID` (Task 1) resolved by id in the VM ✔; `removeAnnotation(_ annotation:)` signature used by both navigators + VM ✔; `Locator.pageQuads`/`anchorKey` (Task 1) used by PDF mapping (Task 5) and bookmark identity (Task 2) ✔; `NavigatorFactory.make` gains `formatID`+`caches` params in Task 9, consistent with its Task 2 introduction (the plan calls out the signature growth) ✔.
- **Known risk points:** PDFView/PDFThumbnailView instantiate headlessly in `swift test` on macOS — if the relocate/selection observers prove flaky like the WebKit suites, use deterministic waits and report DONE_WITH_CONCERNS (never silent-skip); the pure `PDFAnnotationMapping`/`ComicExtractor`/`toc` cores are view-free and deterministic. The `ScrollView`+`scrollPosition` paging API is iOS 17/macOS 14 (matches floors). `openableFormat` widens twice (Task 6 pdf, Task 9 cbz) — each task owns its widening. The M3 EPUB tests that construct `SelectionInfo`/`SearchHit` must be updated for the new `locator` field (Tasks 4/5 call this out).

## Execution

Plan complete. Execute with superpowers:subagent-driven-development (fresh subagent per task, review between tasks) or superpowers:executing-plans (inline with checkpoints).
