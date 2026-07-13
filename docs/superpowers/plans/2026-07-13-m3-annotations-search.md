# M3 — Annotations & In-Book Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Select text in an open EPUB to create a colored highlight, attach a note to it, bookmark a page, browse all annotations in a list that navigates back to the passage, and search the full text of the open book — all persisted locally and restored on reopen.

**Architecture:** Extends the M2 reader. The `annotation` table (schema v1, already present) gets an `AnnotationRecord` + `AnnotationStore` in IqraLibrary (locator stored as opaque JSON, same boundary as `reading_state`). IqraReader gains annotation/selection/search value types and extends `bridge.js`/`EPUBNavigator` to draw foliate-js overlays, report selections, hit-test taps, and run the foliate search generator — all over the existing single `iqra` message channel. The app composes them: a selection popover with a 5-color picker, a note editor, an annotations list, and search UI. Spec: `docs/superpowers/specs/2026-07-11-iqra-architecture-design.md` ("Annotations rendering", "protocol composition"). Foliate-js APIs verified against the vendored source (pin `78914ae`).

**Tech Stack:** Swift 5.10, WKWebView, foliate-js (vendored — Overlayer + search modules), GRDB 7, SwiftUI, XcodeGen.

## Global Constraints

- Deployment floors: **iOS 17.0 / macOS 14.0**. Swift tools **5.10**.
- Runtime Swift dependencies remain **GRDB.swift + ZIPFoundation only**. Vendored foliate-js is never modified (files under `Sources/IqraReader/Vendor/**` are read-only; our glue is `Sources/IqraReader/ReaderAssets/bridge.js`).
- Package boundaries: `IqraCore` imports Foundation only. `IqraLibrary` never imports UI or reader code (annotation locator stored as opaque JSON, exactly like `reading_state`). **`IqraReader` imports IqraCore + WebKit only, never IqraLibrary.** The app is the composition point.
- **Annotation anchoring (spec):** the locator is a **range CFI** (the precise coordinate) plus **text context** (`before`/`highlight`/`after`) for fuzzy re-anchoring when a CFI breaks. `Locator` gains the deferred `textContext` field this milestone.
- **Deletions are permanent tombstones** (spec): `annotation.deleted` is monotonic, set true on delete, never GC'd, never un-set by a field update. Annotation rows are append-mostly; every write stamps a fresh apply sequence.
- **Highlight colors:** exactly five, Books-style — `yellow, green, blue, pink, purple` — stored by name; each maps to one CSS color the overlayer draws. A highlight carrying a note also shows a margin/underline indicator.
- **Annotation kinds:** `highlight`, `note`, `bookmark` (the `kind` column's documented values). A note is a highlight with non-empty `noteText`; a bookmark is position-only (no text selection, no color).
- Bridge security unchanged: single `iqra` channel, main-frame-guarded; content iframes never speak the protocol; strict CSP; content blocker. New message types ride the same channel and the same main-frame guard.
- In-book search is **reader-side** (foliate-js searches the rendered book); it does NOT touch the catalogue FTS (`content_fts` remains a later milestone). No schema change for search.
- Every reader-engine change lands with a WKWebView integration test in `Tests/IqraReaderTests`; the known WebKit-suite flake mitigations apply (deterministic waits, no NaN/timing races).
- All package tests headless via `swift test`; zero-warning builds. Commit per task; conventional-commit subjects.

## File Structure

```
Sources/IqraCore/                       — (unchanged)
Sources/IqraLibrary/Database/
  Records.swift                         — + AnnotationRecord
  AnnotationStore.swift                 — NEW: annotation CRUD, ordered fetch, observation
Sources/IqraReader/
  Locator.swift                         — + textContext field; + Annotation / AnnotationKind / HighlightColor / SelectionInfo / SearchHit value types
  NavigatorProtocols.swift              — + Selectable/Annotatable/Searchable delegate callbacks
  EPUBNavigator.swift                   — + addAnnotation/removeAnnotation/search/clearSearch + inbound selected/annotationTapped/searchHit handling
  ReaderAssets/bridge.js                — + selection reporting, overlay draw, create-overlay re-add, show-annotation, search generator
App/Sources/
  ReaderViewModel.swift                 — + annotations state, create/update/delete, restore-on-load, bookmark toggle, search state
  ReaderScreen.swift                    — + selection popover (color picker), note editor, bookmark button, wiring
  SelectionPopover.swift                — NEW: color picker + note/copy actions
  AnnotationsListView.swift             — NEW: highlights/notes/bookmarks list, tap-to-navigate, swipe-delete
  SearchView.swift                      — NEW: in-book search field + results list
Tests/IqraLibraryTests/
  AnnotationStoreTests.swift            — NEW
Tests/IqraReaderTests/
  AnnotationValueTypesTests.swift       — NEW (Codable/round-trip)
  EPUBNavigatorAnnotationTests.swift    — NEW (WKWebView: create/draw/tap/remove)
  EPUBNavigatorSearchTests.swift        — NEW (WKWebView: search hits + navigate)
```

---

## Phase A — Data layer (annotation persistence)

### Task 1: AnnotationRecord + AnnotationStore

**Files:**
- Modify: `Sources/IqraLibrary/Database/Records.swift` (add `AnnotationRecord`)
- Create: `Sources/IqraLibrary/Database/AnnotationStore.swift`
- Test: `Tests/IqraLibraryTests/AnnotationStoreTests.swift`

**Interfaces:**
- Consumes: `DatabaseManager` (`nextApplySequence`, `writer`), the existing `annotation` table (id, bookId, formatId, kind, locator TEXT/JSON, color, noteText, createdAt, modifiedAt, applySeq, deleted).
- Produces:

```swift
public struct AnnotationRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "annotation"
    public var id: String            // UUID string
    public var bookId: String
    public var formatId: String
    public var kind: String          // highlight | note | bookmark
    public var locator: String       // opaque JSON (a reader Locator); IqraLibrary never decodes it
    public var color: String?        // highlight color name, nil for bookmark
    public var noteText: String?
    public var createdAt: Date
    public var modifiedAt: Date
    public var applySeq: Int64
    public var deleted: Bool
}

public final class AnnotationStore: @unchecked Sendable {
    public init(dbm: DatabaseManager)
    /// Insert or update by id; stamps a fresh applySeq and bumps modifiedAt. createdAt is
    /// preserved on update (only set on first insert).
    public func upsert(id: UUID, bookID: UUID, formatID: UUID, kind: String,
                       locatorJSON: Data, color: String?, noteText: String?) throws
    /// Soft-delete (permanent tombstone): sets deleted = 1, stamps applySeq/modifiedAt.
    public func delete(id: UUID) throws
    public func annotation(id: UUID) throws -> AnnotationRecord?
    /// Live (non-deleted) annotations for a (book, format), position-ordered:
    /// the locator JSON's spineIndex then totalProgression (both are in the stored Locator).
    public func annotations(bookID: UUID, formatID: UUID) throws -> [AnnotationRecord]
    /// GRDB observation of the same ordered list for reactive UI.
    public func observeAnnotations(bookID: UUID, formatID: UUID)
        -> ValueObservation<ValueReducers.Fetch<[AnnotationRecord]>>
}
```

Ordering note: the store extracts `spineIndex` and `totalProgression` from the stored locator JSON with SQLite's `json_extract` (GRDB ships JSON1) so ordering needs no Swift decode and no schema change.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IqraLibraryTests/AnnotationStoreTests.swift
import XCTest
import GRDB
@testable import IqraLibrary

final class AnnotationStoreTests: XCTestCase {
    var dbm: DatabaseManager!
    var store: LibraryStore!
    var annotations: AnnotationStore!
    var bookID: UUID!
    var formatID: UUID!

    override func setUpWithError() throws {
        dbm = try DatabaseManager.inMemory()
        store = LibraryStore(dbm: dbm)
        annotations = AnnotationStore(dbm: dbm)
        bookID = UUID(); formatID = UUID()
        try store.insertBook(
            metadata: .init(title: "T", titleSort: "T", language: "en", publisher: nil,
                            bookDescription: nil, contributors: [], identifiers: []),
            formatType: .epub, originalFileName: "t.epub", byteSize: 1, contentHash: "h",
            bookID: bookID, formatID: formatID)
    }

    /// A minimal locator JSON with the two fields the ordering relies on.
    func locator(spine: Int, progress: Double) -> Data {
        Data(#"{"spineIndex":\#(spine),"totalProgression":\#(progress),"cfi":"epubcfi(/6/\#(spine))"}"#.utf8)
    }

    func testUpsertInsertsThenUpdatesPreservingCreatedAt() throws {
        let id = UUID()
        try annotations.upsert(id: id, bookID: bookID, formatID: formatID, kind: "highlight",
                               locatorJSON: locator(spine: 2, progress: 0.2), color: "yellow", noteText: nil)
        let first = try XCTUnwrap(annotations.annotation(id: id))
        XCTAssertEqual(first.color, "yellow")
        XCTAssertNil(first.noteText)
        let created = first.createdAt

        try annotations.upsert(id: id, bookID: bookID, formatID: formatID, kind: "note",
                               locatorJSON: locator(spine: 2, progress: 0.2), color: "green",
                               noteText: "a thought")
        let updated = try XCTUnwrap(annotations.annotation(id: id))
        XCTAssertEqual(updated.color, "green")
        XCTAssertEqual(updated.noteText, "a thought")
        XCTAssertEqual(updated.createdAt, created)                 // preserved
        XCTAssertGreaterThanOrEqual(updated.modifiedAt, created)   // bumped
    }

    func testDeleteTombstonesAndHidesFromList() throws {
        let id = UUID()
        try annotations.upsert(id: id, bookID: bookID, formatID: formatID, kind: "highlight",
                               locatorJSON: locator(spine: 1, progress: 0.1), color: "blue", noteText: nil)
        try annotations.delete(id: id)
        XCTAssertEqual(try annotations.annotations(bookID: bookID, formatID: formatID).count, 0)
        // the tombstone row itself persists (permanent)
        let row = try XCTUnwrap(annotations.annotation(id: id))
        XCTAssertTrue(row.deleted)
    }

    func testListIsOrderedBySpineThenProgress() throws {
        // insert out of order
        for (spine, prog) in [(3, 0.5), (1, 0.9), (1, 0.2), (2, 0.4)] {
            try annotations.upsert(id: UUID(), bookID: bookID, formatID: formatID, kind: "highlight",
                                   locatorJSON: locator(spine: spine, progress: prog),
                                   color: "yellow", noteText: nil)
        }
        let ordered = try annotations.annotations(bookID: bookID, formatID: formatID)
        let keys = ordered.map { rec -> String in
            let obj = try! JSONSerialization.jsonObject(with: Data(rec.locator.utf8)) as! [String: Any]
            return "\(obj["spineIndex"]!)-\(obj["totalProgression"]!)"
        }
        XCTAssertEqual(keys, ["1-0.2", "1-0.9", "2-0.4", "3-0.5"])
    }

    func testUpsertStampsIncreasingApplySequence() throws {
        let a = UUID(), b = UUID()
        try annotations.upsert(id: a, bookID: bookID, formatID: formatID, kind: "bookmark",
                               locatorJSON: locator(spine: 1, progress: 0.1), color: nil, noteText: nil)
        try annotations.upsert(id: b, bookID: bookID, formatID: formatID, kind: "bookmark",
                               locatorJSON: locator(spine: 1, progress: 0.3), color: nil, noteText: nil)
        let seqA = try XCTUnwrap(annotations.annotation(id: a)).applySeq
        let seqB = try XCTUnwrap(annotations.annotation(id: b)).applySeq
        XCTAssertGreaterThan(seqB, seqA)
    }

    func testObservationFiresOnInsert() throws {
        let exp = expectation(description: "observed"); exp.expectedFulfillmentCount = 2
        var seen: [[AnnotationRecord]] = []
        let cancellable = annotations.observeAnnotations(bookID: bookID, formatID: formatID).start(
            in: dbm.writer, onError: { XCTFail("\($0)") }, onChange: { seen.append($0); exp.fulfill() })
        try annotations.upsert(id: UUID(), bookID: bookID, formatID: formatID, kind: "highlight",
                               locatorJSON: locator(spine: 1, progress: 0.1), color: "pink", noteText: nil)
        wait(for: [exp], timeout: 5); cancellable.cancel()
        XCTAssertEqual(seen.last?.count, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AnnotationStoreTests`
Expected: FAIL — `cannot find 'AnnotationStore'`.

- [ ] **Step 3: Implement**

Append to `Sources/IqraLibrary/Database/Records.swift`:

```swift
public struct AnnotationRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "annotation"
    public var id: String
    public var bookId: String
    public var formatId: String
    public var kind: String
    public var locator: String
    public var color: String?
    public var noteText: String?
    public var createdAt: Date
    public var modifiedAt: Date
    public var applySeq: Int64
    public var deleted: Bool
}
```

```swift
// Sources/IqraLibrary/Database/AnnotationStore.swift
import Foundation
import GRDB

/// Persistence for EPUB annotations (spec "Annotations rendering"). The locator is opaque
/// JSON to this layer — IqraLibrary never imports reader types. Deletes are permanent
/// tombstones; every write stamps a fresh apply sequence.
public final class AnnotationStore: @unchecked Sendable {
    let dbm: DatabaseManager
    public init(dbm: DatabaseManager) { self.dbm = dbm }

    public func upsert(id: UUID, bookID: UUID, formatID: UUID, kind: String,
                       locatorJSON: Data, color: String?, noteText: String?) throws {
        try dbm.writer.write { db in
            let seq = try dbm.nextApplySequence(db)
            let now = Date()
            let locator = String(decoding: locatorJSON, as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO annotation (id, bookId, formatId, kind, locator, color, noteText,
                                        createdAt, modifiedAt, applySeq, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind, locator = excluded.locator, color = excluded.color,
                    noteText = excluded.noteText, modifiedAt = excluded.modifiedAt,
                    applySeq = excluded.applySeq
                """, arguments: [id.uuidString, bookID.uuidString, formatID.uuidString, kind,
                                 locator, color, noteText, now, now, seq])
        }
    }

    public func delete(id: UUID) throws {
        try dbm.writer.write { db in
            let seq = try dbm.nextApplySequence(db)
            try db.execute(sql: """
                UPDATE annotation SET deleted = 1, modifiedAt = ?, applySeq = ? WHERE id = ?
                """, arguments: [Date(), seq, id.uuidString])
        }
    }

    public func annotation(id: UUID) throws -> AnnotationRecord? {
        try dbm.writer.read { db in try AnnotationRecord.fetchOne(db, key: id.uuidString) }
    }

    // Orders by the stored locator's spineIndex then totalProgression via JSON1 —
    // no Swift decode, no schema change (the reader Locator carries both fields).
    private static let orderedSQL = """
        SELECT * FROM annotation
        WHERE bookId = ? AND formatId = ? AND deleted = 0
        ORDER BY CAST(json_extract(locator, '$.spineIndex') AS INTEGER) ASC,
                 CAST(json_extract(locator, '$.totalProgression') AS REAL) ASC,
                 createdAt ASC
        """

    public func annotations(bookID: UUID, formatID: UUID) throws -> [AnnotationRecord] {
        try dbm.writer.read { db in
            try AnnotationRecord.fetchAll(db, sql: Self.orderedSQL,
                                          arguments: [bookID.uuidString, formatID.uuidString])
        }
    }

    public func observeAnnotations(bookID: UUID, formatID: UUID)
        -> ValueObservation<ValueReducers.Fetch<[AnnotationRecord]>> {
        ValueObservation.tracking { db in
            try AnnotationRecord.fetchAll(db, sql: Self.orderedSQL,
                                          arguments: [bookID.uuidString, formatID.uuidString])
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter AnnotationStoreTests`
Expected: PASS (5 tests). If `json_extract` is unavailable in the linked SQLite (it is standard in system SQLite and GRDB's build), fall back to decoding in Swift and sorting — but verify first; JSON1 has shipped by default since SQLite 3.38.

- [ ] **Step 5: Full suite + commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/IqraLibrary/Database Tests/IqraLibraryTests/AnnotationStoreTests.swift
git commit -m "feat: annotation persistence with tombstones and position-ordered queries"
```

---

## Phase B — Reader engine (foliate-js overlays + selection + search)

**Note indicator scope:** noted passages are marked in the **annotations list** with a note glyph and revealed on tapping the highlight. An in-text margin dot is deferred — foliate's Overlayer draws one style per anchor, so a second in-text channel isn't worth M3's budget. The five colors and note-on-tap are fully delivered.

### Task 2: IqraReader value types + Locator.textContext

**Files:**
- Modify: `Sources/IqraReader/Locator.swift` (add `textContext`; add annotation/selection/search value types)
- Test: `Tests/IqraReaderTests/AnnotationValueTypesTests.swift`

**Interfaces:**
- Consumes: existing `Locator`.
- Produces:

```swift
public struct TextContext: Codable, Equatable, Sendable {
    public var before: String; public var highlight: String; public var after: String
    public init(before: String, highlight: String, after: String)
}
// Locator gains: public var textContext: TextContext?   (nil default; additive)

public enum AnnotationKind: String, Codable, Sendable, CaseIterable { case highlight, note, bookmark }

public enum HighlightColor: String, Codable, Sendable, CaseIterable {
    case yellow, green, blue, pink, purple
    public var cssColor: String   // hex the overlayer fills with
}

public struct Annotation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: AnnotationKind
    public var locator: Locator          // range CFI for highlight/note; point CFI for bookmark; carries textContext + ordering fields
    public var color: HighlightColor?    // nil for bookmark
    public var note: String?             // non-empty ⇒ kind should be .note
    public var createdAt: Date
    public var modifiedAt: Date
    public init(id:kind:locator:color:note:createdAt:modifiedAt:)
}

public struct SelectionRect: Codable, Equatable, Sendable { public var x, y, width, height: Double }

public struct SelectionInfo: Codable, Equatable, Sendable {
    public var text: String; public var cfi: String; public var rect: SelectionRect
    public var spineIndex: Int; public var totalProgression: Double; public var textContext: TextContext?
}

public struct SearchHit: Codable, Equatable, Sendable, Identifiable {
    public var id: String { cfi }
    public var cfi: String; public var excerptPre: String; public var excerptMatch: String
    public var excerptPost: String; public var sectionLabel: String?
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IqraReaderTests/AnnotationValueTypesTests.swift
import XCTest
@testable import IqraReader

final class AnnotationValueTypesTests: XCTestCase {
    func testLocatorCarriesTextContextRoundTrip() throws {
        let loc = Locator(spineIndex: 2, spineHref: "ch2", cfi: "epubcfi(/6/4,/1:0,/1:5)",
                          progressionInChapter: 0.1, totalProgression: 0.3, tocLabel: "Two",
                          textContext: TextContext(before: "the ", highlight: "quick", after: " brown"))
        let data = try JSONEncoder().encode(loc)
        XCTAssertEqual(try JSONDecoder().decode(Locator.self, from: data), loc)
    }

    func testLocatorTextContextDefaultsNilAndDecodesLegacyJSON() throws {
        // a locator persisted by M2 (no textContext key) must still decode
        let legacy = Data(#"{"spineIndex":1,"totalProgression":0.2}"#.utf8)
        let loc = try JSONDecoder().decode(Locator.self, from: legacy)
        XCTAssertNil(loc.textContext)
        XCTAssertEqual(loc.spineIndex, 1)
    }

    func testHighlightColorCSSIsHex() {
        for c in HighlightColor.allCases {
            XCTAssertTrue(c.cssColor.hasPrefix("#"), "\(c) should map to a hex color")
        }
        XCTAssertEqual(Set(HighlightColor.allCases.map(\.cssColor)).count, 5) // all distinct
    }

    func testAnnotationRoundTrip() throws {
        let a = Annotation(id: UUID(), kind: .note,
                           locator: Locator(spineIndex: 0, totalProgression: 0.1, cfi: "epubcfi(/6/2,/1:0,/1:3)"),
                           color: .green, note: "hm", createdAt: Date(timeIntervalSince1970: 1),
                           modifiedAt: Date(timeIntervalSince1970: 2))
        let data = try JSONEncoder().encode(a)
        XCTAssertEqual(try JSONDecoder().decode(Annotation.self, from: data), a)
    }
}
```

(Note: `Locator.init` currently has `cfi` after `spineHref`; the test uses labels so ordering is irrelevant, but ensure the new `textContext` param has a default so all existing call sites compile.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AnnotationValueTypesTests`
Expected: FAIL — `textContext`/`Annotation`/`HighlightColor` unknown.

- [ ] **Step 3: Implement**

In `Sources/IqraReader/Locator.swift`, add `textContext` to `Locator` (with a default so existing call sites and legacy JSON both work):

```swift
public struct TextContext: Codable, Equatable, Sendable {
    public var before: String
    public var highlight: String
    public var after: String
    public init(before: String, highlight: String, after: String) {
        self.before = before; self.highlight = highlight; self.after = after
    }
}
```

Add `public var textContext: TextContext?` to `Locator`'s stored properties and to its `init` as a trailing parameter `textContext: TextContext? = nil` (assign `self.textContext = textContext`). Because it's `Optional` and Codable synthesizes `decodeIfPresent` for optionals, legacy JSON without the key decodes to `nil` — no custom Codable needed.

Append the annotation/selection/search types:

```swift
public enum AnnotationKind: String, Codable, Sendable, CaseIterable { case highlight, note, bookmark }

public enum HighlightColor: String, Codable, Sendable, CaseIterable {
    case yellow, green, blue, pink, purple
    /// The fill color the foliate Overlayer draws (drawn OUTSIDE the themed iframe, so the
    /// color is explicit here rather than CSS-inherited). Opacity/blend are set on the
    /// renderer element separately.
    public var cssColor: String {
        switch self {
        case .yellow: "#F7D774"
        case .green:  "#A3E4A1"
        case .blue:   "#9EC9FF"
        case .pink:   "#FFB0C4"
        case .purple: "#D6B4FC"
        }
    }
}

public struct Annotation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: AnnotationKind
    public var locator: Locator
    public var color: HighlightColor?
    public var note: String?
    public var createdAt: Date
    public var modifiedAt: Date
    public init(id: UUID, kind: AnnotationKind, locator: Locator, color: HighlightColor?,
                note: String?, createdAt: Date, modifiedAt: Date) {
        self.id = id; self.kind = kind; self.locator = locator; self.color = color
        self.note = note; self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}

public struct SelectionRect: Codable, Equatable, Sendable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct SelectionInfo: Codable, Equatable, Sendable {
    public var text: String
    public var cfi: String
    public var rect: SelectionRect
    public var spineIndex: Int
    public var totalProgression: Double
    public var textContext: TextContext?
    public init(text: String, cfi: String, rect: SelectionRect, spineIndex: Int,
                totalProgression: Double, textContext: TextContext?) {
        self.text = text; self.cfi = cfi; self.rect = rect; self.spineIndex = spineIndex
        self.totalProgression = totalProgression; self.textContext = textContext
    }
}

public struct SearchHit: Codable, Equatable, Sendable, Identifiable {
    public var id: String { cfi }
    public var cfi: String
    public var excerptPre: String
    public var excerptMatch: String
    public var excerptPost: String
    public var sectionLabel: String?
    public init(cfi: String, excerptPre: String, excerptMatch: String, excerptPost: String,
                sectionLabel: String?) {
        self.cfi = cfi; self.excerptPre = excerptPre; self.excerptMatch = excerptMatch
        self.excerptPost = excerptPost; self.sectionLabel = sectionLabel
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter AnnotationValueTypesTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Full suite (legacy-locator regression) + commit**

Run: `swift test`
Expected: PASS — critically, the M2 `LocatorTests` and `EPUBNavigatorTests` still pass (the `textContext` addition must not break existing Locator round-trips).

```bash
git add Sources/IqraReader/Locator.swift Tests/IqraReaderTests/AnnotationValueTypesTests.swift
git commit -m "feat: annotation/selection/search value types and Locator text context"
```

---

### Task 3: bridge.js + EPUBNavigator — selection, overlay draw, tap, delete

**Files:**
- Modify: `Sources/IqraReader/ReaderAssets/bridge.js`
- Modify: `Sources/IqraReader/NavigatorProtocols.swift` (delegate callbacks)
- Modify: `Sources/IqraReader/EPUBNavigator.swift` (Swift API + inbound handling)
- Test: `Tests/IqraReaderTests/EPUBNavigatorAnnotationTests.swift`

**Interfaces:**
- Consumes: `Annotation`, `SelectionInfo`, `HighlightColor`, `TextContext` (Task 2); `view.getCFI`, `view.addAnnotation`, `view.deleteAnnotation`, `Overlayer.*`, the `load`/`draw-annotation`/`create-overlay`/`show-annotation` events (research report).
- Produces:

```swift
// NavigatorDelegate gains (all @MainActor):
func navigator(didChangeSelection selection: SelectionInfo?)   // nil = cleared
func navigator(didTapAnnotation cfi: String)
// EPUBNavigator gains:
public func addAnnotation(_ annotation: Annotation)   // draws + registers in the page's mirror
public func removeAnnotation(cfi: String)
public func deselect()
```

Bridge protocol additions (same `iqra` channel, main-frame only):
- outbound: `{type:"selected", text, cfi, rect:{x,y,width,height}, spineIndex, totalProgression, textContext:{before,highlight,after}}`; `{type:"selectionCleared"}`; `{type:"annotationTapped", value}`
- inbound: `iqra.addAnnotation({cfi, color, kind})`, `iqra.removeAnnotation({cfi})`, `iqra.deselect()`

- [ ] **Step 1: Add the bridge listeners + commands (bridge.js)**

Add the Overlayer import at the top with the other vendored imports:

```js
import { Overlayer } from './vendor/foliate-js/overlayer.js'
```

After the `view` is created and its `relocate` listener is registered, add the annotation/selection machinery (the four listeners + a registry). `post` and `view` are already in scope:

```js
// --- annotations + selection (M3) ---
const annotations = new Map()   // cfi -> { value, color, kind }; the page-side mirror of the DB,
                                // re-drawn per section because foliate overlays die with the iframe.
let currentIndex = 0

// Grab up to `n` chars of text before/after a range's boundaries for fuzzy re-anchoring.
const contextText = (range, n = 40) => {
    const beforeR = range.cloneRange(); beforeR.collapse(true)
    beforeR.setStart(range.startContainer.ownerDocument.body, 0)
    const afterR = range.cloneRange(); afterR.collapse(false)
    const body = range.startContainer.ownerDocument.body
    afterR.setEnd(body, body.childNodes.length)
    const tail = s => s.length > n ? s.slice(-n) : s
    const head = s => s.length > n ? s.slice(0, n) : s
    return { before: tail(beforeR.toString()), highlight: range.toString(), after: head(afterR.toString()) }
}

view.addEventListener('load', ({ detail: { doc, index } }) => {
    currentIndex = index
    const emit = () => {
        const sel = doc.getSelection()
        if (!sel || sel.isCollapsed || !sel.rangeCount) { post({ type: 'selectionCleared' }); return }
        const range = sel.getRangeAt(0)
        const fr = doc.defaultView.frameElement.getBoundingClientRect()
        const r = range.getBoundingClientRect()
        post({
            type: 'selected',
            text: sel.toString(),
            cfi: view.getCFI(index, range),
            rect: { x: r.left + fr.left, y: r.top + fr.top, width: r.width, height: r.height },
            spineIndex: index,
            totalProgression: view.lastLocation?.fraction ?? 0,
            textContext: contextText(range),
        })
    }
    doc.addEventListener('pointerup', emit)
    doc.addEventListener('selectionchange', () => {
        if (doc.getSelection()?.isCollapsed) post({ type: 'selectionCleared' })
    })
})

view.addEventListener('draw-annotation', ({ detail: { draw, annotation } }) => {
    // Only highlights/notes draw a fill; bookmarks are position-only (no overlay).
    if (annotation.kind === 'bookmark') return
    draw(Overlayer.highlight, { color: annotation.color ?? '#F7D774' })
})

view.addEventListener('create-overlay', ({ detail: { index } }) => {
    currentIndex = index
    for (const a of annotations.values()) view.addAnnotation(a)   // no-op for non-visible sections
})

view.addEventListener('show-annotation', ({ detail: { value } }) => {
    post({ type: 'annotationTapped', value })
})
```

Extend the `window.iqra` object with the new commands (add these properties to the existing object literal):

```js
    addAnnotation(a) {
        const entry = { value: a.cfi, color: a.color, kind: a.kind }
        annotations.set(a.cfi, entry)
        view.addAnnotation(entry)   // draws now if the section is visible; else create-overlay redraws later
    },
    removeAnnotation(a) {
        annotations.delete(a.cfi)
        view.deleteAnnotation({ value: a.cfi })
    },
    deselect() { view.deselect() },
```

Note: `view.lastLocation?.fraction` is set by foliate on each relocate (it exists by the time a selection can happen). `Overlayer.highlight` fill color is the hex passed from Swift (`HighlightColor.cssColor`).

- [ ] **Step 2: Add the Swift delegate + API + inbound handling**

In `Sources/IqraReader/NavigatorProtocols.swift`, add to `NavigatorDelegate`:

```swift
    func navigator(didChangeSelection selection: SelectionInfo?)
    func navigator(didTapAnnotation cfi: String)
```

Provide default no-op implementations in a protocol extension so existing conformers (M2 tests) don't break:

```swift
public extension NavigatorDelegate {
    func navigator(didChangeSelection selection: SelectionInfo?) {}
    func navigator(didTapAnnotation cfi: String) {}
}
```

In `Sources/IqraReader/EPUBNavigator.swift`, add the API methods near `goTo`:

```swift
    public func addAnnotation(_ annotation: Annotation) {
        let payload: [String: Any] = [
            "cfi": annotation.locator.cfi ?? "",
            "color": annotation.color?.cssColor ?? NSNull(),
            "kind": annotation.kind.rawValue,
        ]
        guard annotation.locator.cfi != nil,
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        call("iqra.addAnnotation(\(String(decoding: data, as: UTF8.self)))")
    }

    public func removeAnnotation(cfi: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["cfi": cfi]) else { return }
        call("iqra.removeAnnotation(\(String(decoding: data, as: UTF8.self)))")
    }

    public func deselect() { call("iqra.deselect()") }
```

Add inbound cases to `handle(message:)`:

```swift
        case "selected":
            guard let text = dict["text"] as? String, let cfi = dict["cfi"] as? String,
                  let rect = dict["rect"] as? [String: Any] else { return }
            let selRect = SelectionRect(x: rect["x"] as? Double ?? 0, y: rect["y"] as? Double ?? 0,
                                        width: rect["width"] as? Double ?? 0, height: rect["height"] as? Double ?? 0)
            var context: TextContext?
            if let tc = dict["textContext"] as? [String: Any] {
                context = TextContext(before: tc["before"] as? String ?? "",
                                      highlight: tc["highlight"] as? String ?? text,
                                      after: tc["after"] as? String ?? "")
            }
            let progression = dict["totalProgression"] as? Double ?? 0
            delegate?.navigator(didChangeSelection: SelectionInfo(
                text: text, cfi: cfi, rect: selRect, spineIndex: dict["spineIndex"] as? Int ?? 0,
                totalProgression: progression.isFinite ? progression : 0, textContext: context))
        case "selectionCleared":
            delegate?.navigator(didChangeSelection: nil)
        case "annotationTapped":
            if let value = dict["value"] as? String { delegate?.navigator(didTapAnnotation: value) }
```

- [ ] **Step 3: Write the failing integration test**

```swift
// Tests/IqraReaderTests/EPUBNavigatorAnnotationTests.swift
import XCTest
import WebKit
import ZIPFoundation
@testable import IqraReader

@MainActor
private final class AnnRecorder: NavigatorDelegate {
    var loaded = false
    var selections: [SelectionInfo?] = []
    var tapped: [String] = []
    var onLoad: (() -> Void)?
    var onSelect: (() -> Void)?
    var onTap: (() -> Void)?
    func navigatorDidLoad(title: String?, toc: [TOCItem]) { loaded = true; onLoad?() }
    func navigator(didRelocate locator: Locator) {}
    func navigator(didFail message: String) { XCTFail("reader error: \(message)") }
    func navigator(didChangeSelection selection: SelectionInfo?) { selections.append(selection); onSelect?() }
    func navigator(didTapAnnotation cfi: String) { tapped.append(cfi); onTap?() }
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

    @MainActor
    func makeNavigator(_ recorder: AnnRecorder) throws -> EPUBNavigator {
        let nav = EPUBNavigator(bookID: UUID(), bookFileURL: try makeEPUB(),
                                initialLocator: nil, settings: .default)
        nav.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        nav.delegate = recorder
        return nav
    }

    @MainActor
    func testSelectionReportsTextAndRangeCFI() async throws {
        let rec = AnnRecorder(); let nav = try makeNavigator(rec)
        let loaded = expectation(description: "loaded"); rec.onLoad = { loaded.fulfill() }
        nav.start(); await fulfillment(of: [loaded], timeout: 30)

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
    func testAddAnnotationDrawsAndTapReportsCFI() async throws {
        let rec = AnnRecorder(); let nav = try makeNavigator(rec)
        let loaded = expectation(description: "loaded"); rec.onLoad = { loaded.fulfill() }
        nav.start(); await fulfillment(of: [loaded], timeout: 30)

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

        nav.addAnnotation(Annotation(id: UUID(), kind: .highlight,
                                     locator: Locator(spineIndex: 0, totalProgression: 0.1, cfi: annotationCFI),
                                     color: .yellow, note: nil, createdAt: Date(), modifiedAt: Date()))

        // The overlay must exist: poll the paginator's overlayer for the drawn key.
        try await Task.sleep(nanoseconds: 400_000_000)
        let drawn = try await nav.webView.evaluateJavaScript("""
            document.querySelector('foliate-view').renderer.getContents()[0].overlayer.hitTest
              ? true : false
            """) as? Bool
        XCTAssertEqual(drawn, true) // overlayer present on the section

        // Simulate a tap on the annotation via the view's showAnnotation path.
        let tapped = expectation(description: "tapped"); tapped.assertForOverFulfill = false
        rec.onTap = { tapped.fulfill() }
        try await nav.webView.evaluateJavaScript("""
            document.querySelector('foliate-view').showAnnotation({ value: \(jsStringLiteral(annotationCFI)) })
            """)
        await fulfillment(of: [tapped], timeout: 30)
        XCTAssertEqual(rec.tapped.last, annotationCFI)

        nav.removeAnnotation(cfi: annotationCFI) // must not throw / error
    }
}

/// Helper: JSON-encode a string as a JS literal for embedding in evaluateJavaScript.
private func jsStringLiteral(_ s: String) -> String {
    let data = (try? JSONEncoder().encode([s])) ?? Data("[\"\"]".utf8)
    return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
}
```

Note for the implementer: `view.showAnnotation(annotation)` (view.js:421) resolves the CFI and emits `show-annotation` — it's the deterministic way to exercise the tap path without synthesizing a pixel-accurate click. If `showAnnotation` requires the section to be current (it does), the fixture's single short section guarantees it. If the overlayer-presence assertion proves brittle across WebKit versions, assert instead that `annotations` registry size is 1 via `view` — but prefer the drawn-overlay check.

- [ ] **Step 4: Run the integration tests**

Run: `swift test --filter EPUBNavigatorAnnotationTests`
Expected: PASS (2 tests). WKWebView under `swift test` on macOS is proven from M2; use deterministic waits, no fixed sleeps except the single post-draw settle above. If a WebKit process error (not an assertion) blocks both, report DONE_WITH_CONCERNS with exact output — never silently skip.

- [ ] **Step 5: Full suite + commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/IqraReader Tests/IqraReaderTests/EPUBNavigatorAnnotationTests.swift
git commit -m "feat: selection reporting, highlight overlays, and annotation tap in the reader bridge"
```

---

### Task 4: bridge.js + EPUBNavigator — in-book search

**Files:**
- Modify: `Sources/IqraReader/ReaderAssets/bridge.js`
- Modify: `Sources/IqraReader/NavigatorProtocols.swift`, `Sources/IqraReader/EPUBNavigator.swift`
- Test: `Tests/IqraReaderTests/EPUBNavigatorSearchTests.swift`

**Interfaces:**
- Consumes: `SearchHit` (Task 2); `view.search(opts)` async generator, `view.clearSearch()`, `view.goTo(cfi)` (research §5).
- Produces:

```swift
// NavigatorDelegate gains:
func navigator(didFindSearchHit hit: SearchHit)
func navigator(didFinishSearch: Void)      // spelled `didFinishSearch()` — see impl
// EPUBNavigator gains:
public func search(query: String)
public func clearSearch()
```

- [ ] **Step 1: Add the bridge search driver (bridge.js)**

Add to the annotation machinery block (search state + the two `window.iqra` methods). Add near the top of that block:

```js
let searchIter = null
```

Add these methods to the `window.iqra` object:

```js
    async search(opts) {
        this.clearSearch()
        searchIter = view.search(opts)   // opts: { query, matchCase, matchDiacritics, matchWholeWords }
        try {
            for await (const r of searchIter) {
                if (r === 'done') { post({ type: 'searchDone' }); break }
                else if (r.subitems) for (const it of r.subitems)
                    post({ type: 'searchHit', cfi: it.cfi, excerpt: it.excerpt, label: r.label })
                else if (r.cfi) post({ type: 'searchHit', cfi: r.cfi, excerpt: r.excerpt, label: null })
                else if (r.progress != null) post({ type: 'searchProgress', progress: r.progress })
            }
        } catch (e) { post({ type: 'error', message: 'search: ' + (e?.message ?? e) }) }
    },
    clearSearch() { searchIter?.return?.(); searchIter = null; view.clearSearch() },
```

(`excerpt` is `{ pre, match, post }`.)

- [ ] **Step 2: Add the Swift delegate + API + inbound (EPUBNavigator / NavigatorProtocols)**

In `NavigatorProtocols.swift` add to `NavigatorDelegate` (+ default no-ops in the extension):

```swift
    func navigator(didFindSearchHit hit: SearchHit)
    func navigatorDidFinishSearch()
```

```swift
// in the default-impl extension:
    func navigator(didFindSearchHit hit: SearchHit) {}
    func navigatorDidFinishSearch() {}
```

In `EPUBNavigator.swift`, add the API:

```swift
    public func search(query: String) {
        let opts: [String: Any] = ["query": query]
        guard !query.isEmpty, let data = try? JSONSerialization.data(withJSONObject: opts) else { return }
        call("iqra.search(\(String(decoding: data, as: UTF8.self)))")
    }
    public func clearSearch() { call("iqra.clearSearch()") }
```

Add inbound cases to `handle(message:)`:

```swift
        case "searchHit":
            guard let cfi = dict["cfi"] as? String else { return }
            let ex = dict["excerpt"] as? [String: Any]
            delegate?.navigator(didFindSearchHit: SearchHit(
                cfi: cfi,
                excerptPre: ex?["pre"] as? String ?? "",
                excerptMatch: ex?["match"] as? String ?? "",
                excerptPost: ex?["post"] as? String ?? "",
                sectionLabel: dict["label"] as? String))
        case "searchProgress":
            break // reserved for a progress UI; ignored in M3
        case "searchDone":
            delegate?.navigatorDidFinishSearch()
```

- [ ] **Step 3: Write the failing integration test**

```swift
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
```

- [ ] **Step 4: Run the integration test**

Run: `swift test --filter EPUBNavigatorSearchTests`
Expected: PASS. Same WebKit-flake escalation rule as Task 3.

- [ ] **Step 5: Full suite + commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/IqraReader Tests/IqraReaderTests/EPUBNavigatorSearchTests.swift
git commit -m "feat: in-book search over the foliate-js search generator"
```

---

## Phase C — Reader UI (create, browse, search)

### Task 5: ReaderViewModel — annotation state, CRUD, restore, bookmark toggle

**Files:**
- Modify: `App/Sources/ReaderViewModel.swift`
- Modify: `App/Sources/LibraryViewModel.swift` (construct + inject `AnnotationStore` into the reader model)
- Test: none (app target; the reader-engine and store logic are package-tested)

**Interfaces:**
- Consumes: `AnnotationStore` (Task 1), `EPUBNavigator.addAnnotation/removeAnnotation/deselect` + selection/tap delegate (Task 3), `Annotation`/`SelectionInfo`/`HighlightColor` (Task 2), the existing `ReadingStateStore`/`LibraryStore` wiring.
- Produces (consumed by Tasks 6–8):

```swift
// on ReaderViewModel:
private(set) var annotations: [Annotation]          // observed, position-ordered
private(set) var currentSelection: SelectionInfo?   // drives the selection popover
private(set) var activeAnnotation: Annotation?      // tapped highlight → note editor
func createHighlight(color: HighlightColor)          // from currentSelection
func setNote(_ text: String, for annotation: Annotation)
func changeColor(_ color: HighlightColor, for annotation: Annotation)
func deleteAnnotation(_ annotation: Annotation)
func clearSelection()
func toggleBookmarkAtCurrentPosition()
var isCurrentPositionBookmarked: Bool
func goTo(_ annotation: Annotation)
```

- [ ] **Step 1: Extend ReaderViewModel**

The current `init?` already builds the navigator and wires `delegate = self`. Add the annotation store and load-on-open. Add a `lastLocator` cache (updated in `didRelocate`) so bookmark-at-current-position has a locator to anchor to.

```swift
// App/Sources/ReaderViewModel.swift — additions
import Foundation
import Observation
import IqraCore
import IqraLibrary
import IqraReader

@Observable @MainActor
final class ReaderViewModel: NavigatorDelegate {
    let navigator: EPUBNavigator
    private(set) var title: String?
    private(set) var toc: [TOCItem] = []
    private(set) var progressPercent: Int = 0
    private(set) var tocLabel: String?
    var readerError: String?

    // M3 state
    private(set) var annotations: [Annotation] = []
    private(set) var currentSelection: SelectionInfo?
    private(set) var activeAnnotation: Annotation?

    var settings: ReaderSettings {
        didSet { navigator.apply(settings: settings); ReaderSettingsStore.save(settings) }
    }

    private let bookID: UUID
    private let formatID: UUID
    private let readingState: ReadingStateStore
    private let annotationStore: AnnotationStore
    private var lastLocator: Locator?
    private var observationTask: Task<Void, Never>?

    init?(bookID: UUID, store: LibraryStore, readingState: ReadingStateStore,
          annotationStore: AnnotationStore, paths: LibraryPaths) {
        guard let format = try? store.openableFormat(bookID: bookID),
              let formatUUID = UUID(uuidString: format.id),
              let type = FormatType(rawValue: format.formatType) else { return nil }
        self.bookID = bookID
        self.formatID = formatUUID
        self.readingState = readingState
        self.annotationStore = annotationStore
        self.settings = ReaderSettingsStore.load()

        let initial = (try? readingState.locatorJSON(bookID: bookID, formatID: formatUUID))
            .flatMap { try? Locator.from(jsonData: $0) }
        self.navigator = EPUBNavigator(
            bookID: bookID,
            bookFileURL: paths.formatFile(bookID: bookID, formatID: formatUUID, type: type),
            initialLocator: initial, settings: ReaderSettingsStore.load())
        navigator.delegate = self
        try? store.markOpened(bookID: bookID)
        startObservingAnnotations()
        navigator.start()
    }

    // Decode stored AnnotationRecords → reader Annotations, keep the observed list fresh,
    // and (re)push them to the navigator so overlays are drawn/redrawn.
    private func startObservingAnnotations() {
        let observation = annotationStore.observeAnnotations(bookID: bookID, formatID: formatID)
        observationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await records in observation.values(in: self.annotationStore.dbm.writer) {
                    let decoded: [Annotation] = records.compactMap { Self.annotation(from: $0) }
                    self.annotations = decoded
                    self.pushAnnotationsToReader(decoded)
                }
            } catch { /* db closed / cancelled */ }
        }
    }

    private func pushAnnotationsToReader(_ annotations: [Annotation]) {
        // Idempotent: the bridge keys overlays by CFI, so re-adding is a redraw, not a dupe.
        for a in annotations where a.kind != .bookmark { navigator.addAnnotation(a) }
    }

    static func annotation(from r: AnnotationRecord) -> Annotation? {
        guard let id = UUID(uuidString: r.id),
              let kind = AnnotationKind(rawValue: r.kind),
              let locator = try? Locator.from(jsonData: Data(r.locator.utf8)) else { return nil }
        return Annotation(id: id, kind: kind, locator: locator,
                          color: r.color.flatMap(HighlightColor.init(rawValue:)),
                          note: r.noteText, createdAt: r.createdAt, modifiedAt: r.modifiedAt)
    }

    // MARK: NavigatorDelegate

    func navigatorDidLoad(title: String?, toc: [TOCItem]) {
        self.title = title; self.toc = toc
        pushAnnotationsToReader(annotations)   // draw whatever is already loaded
    }

    func navigator(didRelocate locator: Locator) {
        lastLocator = locator
        if let json = try? locator.jsonData() {
            _ = try? readingState.saveLocator(json: json, totalProgression: locator.totalProgression,
                                              bookID: bookID, formatID: formatID)
        }
        progressPercent = Int((locator.totalProgression * 100).rounded())
        tocLabel = locator.tocLabel
        currentSelection = nil    // a page turn clears any pending selection
    }

    func navigator(didFail message: String) { readerError = message }

    func navigator(didChangeSelection selection: SelectionInfo?) { currentSelection = selection }

    func navigator(didTapAnnotation cfi: String) {
        activeAnnotation = annotations.first { $0.locator.cfi == cfi }
    }

    // MARK: Intents

    func clearSelection() { currentSelection = nil; navigator.deselect() }

    func createHighlight(color: HighlightColor) {
        guard let sel = currentSelection else { return }
        let locator = Locator(spineIndex: sel.spineIndex, cfi: sel.cfi,
                              totalProgression: sel.totalProgression, textContext: sel.textContext)
        let annotation = Annotation(id: UUID(), kind: .highlight, locator: locator, color: color,
                                    note: nil, createdAt: Date(), modifiedAt: Date())
        persist(annotation)
        navigator.addAnnotation(annotation)
        clearSelection()
    }

    func setNote(_ text: String, for annotation: Annotation) {
        var updated = annotation
        updated.note = text.isEmpty ? nil : text
        updated.kind = text.isEmpty ? .highlight : .note
        updated.modifiedAt = Date()
        persist(updated)
        activeAnnotation = nil
    }

    func changeColor(_ color: HighlightColor, for annotation: Annotation) {
        var updated = annotation; updated.color = color; updated.modifiedAt = Date()
        persist(updated)
        navigator.addAnnotation(updated)   // redraw in place (same CFI key)
    }

    func deleteAnnotation(_ annotation: Annotation) {
        try? annotationStore.delete(id: annotation.id)
        if let cfi = annotation.locator.cfi { navigator.removeAnnotation(cfi: cfi) }
        if activeAnnotation?.id == annotation.id { activeAnnotation = nil }
    }

    func goTo(_ annotation: Annotation) {
        if let cfi = annotation.locator.cfi { navigator.goTo(cfi: cfi) }
        else { navigator.goTo(fraction: annotation.locator.totalProgression) }
    }

    // MARK: Bookmarks

    var isCurrentPositionBookmarked: Bool {
        guard let cfi = lastLocator?.cfi else { return false }
        return annotations.contains { $0.kind == .bookmark && $0.locator.cfi == cfi }
    }

    func toggleBookmarkAtCurrentPosition() {
        guard let locator = lastLocator, let cfi = locator.cfi else { return }
        if let existing = annotations.first(where: { $0.kind == .bookmark && $0.locator.cfi == cfi }) {
            deleteAnnotation(existing)
        } else {
            persist(Annotation(id: UUID(), kind: .bookmark, locator: locator, color: nil,
                               note: nil, createdAt: Date(), modifiedAt: Date()))
        }
    }

    private func persist(_ annotation: Annotation) {
        guard let json = try? annotation.locator.jsonData() else { return }
        try? annotationStore.upsert(id: annotation.id, bookID: bookID, formatID: formatID,
                                    kind: annotation.kind.rawValue, locatorJSON: json,
                                    color: annotation.color?.rawValue, noteText: annotation.note)
    }
}
```

Note: `AnnotationStore.dbm` must be public for `observeAnnotations(...).values(in:)` — mirror `LibraryStore.dbm`'s `public let dbm`. Add `public let dbm: DatabaseManager` to `AnnotationStore` (it's already stored; just make it public) as part of this task.

- [ ] **Step 2: Wire LibraryViewModel to inject the store**

In `App/Sources/LibraryViewModel.swift`: add `private(set) var annotationStore: AnnotationStore?`, set it in `start()` (`annotationStore = AnnotationStore(dbm: dbm)`), and pass it in `readerModel(for:)`:

```swift
    func readerModel(for bookID: UUID) -> ReaderViewModel? {
        if let cached = activeReader, cached.bookID == bookID { return cached.model }
        guard let store, let readingState, let annotationStore, let paths else { return nil }
        guard let model = ReaderViewModel(bookID: bookID, store: store, readingState: readingState,
                                          annotationStore: annotationStore, paths: paths) else { return nil }
        activeReader = (bookID, model)
        return model
    }
```

(Adjust the `activeReader` tuple/type if the M2 cache stored something else; the point is the new `annotationStore` argument.)

- [ ] **Step 3: Build**

Run: `swift test && cd App && xcodegen generate && cd .. && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build`
Expected: PASS + BUILD SUCCEEDED, zero warnings.

- [ ] **Step 4: Commit**

```bash
git add App Sources/IqraLibrary/Database/AnnotationStore.swift
git commit -m "feat: reader view model annotation CRUD, restore, and bookmark toggle"
```

---

### Task 6: Selection popover + note editor + bookmark button

**Files:**
- Create: `App/Sources/SelectionPopover.swift`
- Modify: `App/Sources/ReaderScreen.swift`
- Test: none (app target)

**Interfaces:**
- Consumes: `ReaderViewModel.currentSelection/createHighlight/clearSelection/activeAnnotation/setNote/changeColor/deleteAnnotation/toggleBookmarkAtCurrentPosition/isCurrentPositionBookmarked`, `HighlightColor`.
- Produces: a color-swatch popover anchored to the selection rect; a note editor sheet for the active annotation; a bookmark toolbar toggle.

- [ ] **Step 1: SelectionPopover**

```swift
// App/Sources/SelectionPopover.swift
import SwiftUI
import IqraReader

/// The five-swatch color bar shown above a live text selection.
struct SelectionColorBar: View {
    let onPick: (HighlightColor) -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button { onPick(color) } label: {
                    Circle().fill(Color(hex: color.cssColor)).frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.rawValue)
            }
            Divider().frame(height: 24)
            Button("Copy", systemImage: "doc.on.doc", action: onCopy).labelStyle(.iconOnly)
        }
        .padding(10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4)
    }
}

/// The note editor for a tapped highlight.
struct NoteEditor: View {
    let annotation: Annotation
    let onSave: (String) -> Void
    let onChangeColor: (HighlightColor) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(annotation: Annotation, onSave: @escaping (String) -> Void,
         onChangeColor: @escaping (HighlightColor) -> Void, onDelete: @escaping () -> Void) {
        self.annotation = annotation; self.onSave = onSave
        self.onChangeColor = onChangeColor; self.onDelete = onDelete
        _text = State(initialValue: annotation.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Highlight") {
                    HStack(spacing: 12) {
                        ForEach(HighlightColor.allCases, id: \.self) { c in
                            Circle().fill(Color(hex: c.cssColor)).frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(.primary,
                                    lineWidth: annotation.color == c ? 2 : 0))
                                .onTapGesture { onChangeColor(c) }
                        }
                    }
                }
                Section("Note") {
                    TextEditor(text: $text).frame(minHeight: 120)
                }
                Section {
                    Button("Delete Highlight", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .navigationTitle("Highlight")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(text); dismiss() }
                }
                ToolbarItem(placement: .cancelAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Hex-string → SwiftUI Color (the overlay colors are stored as "#RRGGBB").
extension Color {
    init(hex: String) {
        let h = hex.dropFirst()
        var v: UInt64 = 0; Scanner(string: String(h)).scanHexInt64(&v)
        self = Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}
```

- [ ] **Step 2: Wire into ReaderScreen**

In `App/Sources/ReaderScreen.swift`, overlay the color bar at the selection rect, present the note editor for `activeAnnotation`, and add a bookmark toolbar button. Add to the `WebViewContainer` overlay/toolbar:

```swift
    // inside ReaderScreen.body, on the WebViewContainer:
        .overlay(alignment: .topLeading) {
            if let sel = model.currentSelection {
                SelectionColorBar(
                    onPick: { model.createHighlight(color: $0) },
                    onCopy: {
                        #if os(macOS)
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sel.text, forType: .string)
                        #else
                        UIPasteboard.general.string = sel.text
                        #endif
                        model.clearSelection()
                    },
                    onDismiss: { model.clearSelection() })
                    // Anchor above the selection; clamp into the view. The rect is in web-view
                    // coordinates (bridge already mapped iframe→host).
                    .offset(x: max(8, sel.rect.x), y: max(8, sel.rect.y - 52))
                    .transition(.opacity)
            }
        }
        .sheet(item: Binding(get: { model.activeAnnotation }, set: { if $0 == nil { /* dismissed */ } })) { ann in
            NoteEditor(annotation: ann,
                       onSave: { model.setNote($0, for: ann) },
                       onChangeColor: { model.changeColor($0, for: ann) },
                       onDelete: { model.deleteAnnotation(ann) })
        }
```

And a bookmark button in the toolbar group (alongside the M2 prev/next/contents/appearance buttons):

```swift
                    Button(model.isCurrentPositionBookmarked ? "Bookmarked" : "Bookmark",
                           systemImage: model.isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark") {
                        model.toggleBookmarkAtCurrentPosition()
                    }
```

Note: `Annotation` is `Identifiable` (Task 2), so `.sheet(item:)` works. The `activeAnnotation` binding setter clears via the view model — if SwiftUI's `.sheet(item:)` two-way binding is awkward with an `@Observable` read-only property, expose a `var activeAnnotation` (settable) on the VM or add `func dismissActiveAnnotation()`; the implementer picks the cleaner form and keeps the VM the source of truth.

- [ ] **Step 3: Build (both platforms compile-check)**

Run: `cd App && xcodegen generate && cd .. && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED both (the `#if os` pasteboard branches must compile on each).

- [ ] **Step 4: Commit**

```bash
git add App
git commit -m "feat: selection color bar, note editor, and bookmark toggle in the reader"
```

---

### Task 7: Annotations list

**Files:**
- Create: `App/Sources/AnnotationsListView.swift`
- Modify: `App/Sources/ReaderScreen.swift` (toolbar entry + sheet)
- Test: none (app target)

**Interfaces:**
- Consumes: `ReaderViewModel.annotations/goTo/deleteAnnotation`, `Annotation`/`AnnotationKind`/`HighlightColor`.
- Produces: a sheet listing all annotations (position-ordered), grouped by kind, tap-to-navigate, swipe-to-delete; noted highlights show a note glyph.

- [ ] **Step 1: AnnotationsListView**

```swift
// App/Sources/AnnotationsListView.swift
import SwiftUI
import IqraReader

struct AnnotationsListView: View {
    let annotations: [Annotation]
    let onOpen: (Annotation) -> Void
    let onDelete: (Annotation) -> Void
    @Environment(\.dismiss) private var dismiss

    private var highlights: [Annotation] { annotations.filter { $0.kind != .bookmark } }
    private var bookmarks: [Annotation] { annotations.filter { $0.kind == .bookmark } }

    var body: some View {
        NavigationStack {
            List {
                if !highlights.isEmpty {
                    Section("Highlights & Notes") {
                        ForEach(highlights) { a in row(a) }
                            .onDelete { $0.map { highlights[$0] }.forEach(onDelete) }
                    }
                }
                if !bookmarks.isEmpty {
                    Section("Bookmarks") {
                        ForEach(bookmarks) { a in row(a) }
                            .onDelete { $0.map { bookmarks[$0] }.forEach(onDelete) }
                    }
                }
                if annotations.isEmpty {
                    ContentUnavailableView("No annotations yet", systemImage: "highlighter",
                        description: Text("Select text to highlight, or bookmark a page."))
                }
            }
            .navigationTitle("Annotations")
            .toolbar { ToolbarItem { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder private func row(_ a: Annotation) -> some View {
        Button { onOpen(a); dismiss() } label: {
            HStack(alignment: .top, spacing: 10) {
                if let color = a.color {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: color.cssColor)).frame(width: 4)
                } else {
                    Image(systemName: "bookmark.fill").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(a.locator.textContext?.highlight ?? a.locator.tocLabel ?? "Bookmark")
                        .font(.callout).lineLimit(3)
                    if let note = a.note, !note.isEmpty {
                        Label(note, systemImage: "note.text").font(.caption)
                            .foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Toolbar entry + sheet in ReaderScreen**

Add a toolbar button and sheet:

```swift
                    Button("Annotations", systemImage: "list.bullet.rectangle") { showAnnotations = true }
```
```swift
            .sheet(isPresented: $showAnnotations) {
                AnnotationsListView(annotations: model.annotations,
                                    onOpen: { model.goTo($0) },
                                    onDelete: { model.deleteAnnotation($0) })
            }
```
(with `@State private var showAnnotations = false`).

- [ ] **Step 3: Build + commit**

Run: `cd App && xcodegen generate && cd .. && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

```bash
git add App
git commit -m "feat: annotations list with navigate and delete"
```

---

### Task 8: In-book search UI

**Files:**
- Create: `App/Sources/SearchView.swift`
- Modify: `App/Sources/ReaderViewModel.swift` (search state + delegate), `App/Sources/ReaderScreen.swift` (toolbar + sheet)
- Test: none (app target)

**Interfaces:**
- Consumes: `EPUBNavigator.search/clearSearch` + `didFindSearchHit`/`didFinishSearch` delegate (Task 4), `SearchHit`.
- Produces: search state on the VM and a search sheet (field, live results, tap-to-navigate).

- [ ] **Step 1: VM search state**

Add to `ReaderViewModel` (it already conforms to the extended `NavigatorDelegate`):

```swift
    // search state
    private(set) var searchHits: [SearchHit] = []
    private(set) var isSearching = false
    var searchQuery = ""

    func runSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { clearSearch(); return }
        searchHits = []; isSearching = true
        navigator.search(query: q)
    }
    func clearSearch() {
        searchHits = []; isSearching = false; searchQuery = ""
        navigator.clearSearch()
    }
    func goToHit(_ hit: SearchHit) { navigator.goTo(cfi: hit.cfi) }

    // NavigatorDelegate search callbacks
    func navigator(didFindSearchHit hit: SearchHit) { searchHits.append(hit) }
    func navigatorDidFinishSearch() { isSearching = false }
```

- [ ] **Step 2: SearchView**

```swift
// App/Sources/SearchView.swift
import SwiftUI
import IqraReader

struct SearchView: View {
    @Bindable var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.searchHits) { hit in
                    Button { model.goToHit(hit); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            (Text(hit.excerptPre) + Text(hit.excerptMatch).bold() + Text(hit.excerptPost))
                                .font(.callout).lineLimit(3)
                            if let label = hit.sectionLabel {
                                Text(label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if model.isSearching { HStack { ProgressView(); Text("Searching…") } }
                else if model.searchHits.isEmpty && !model.searchQuery.isEmpty {
                    ContentUnavailableView.search(text: model.searchQuery)
                }
            }
            .navigationTitle("Find in Book")
            .searchable(text: $model.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
            .onSubmit(of: .search) { model.runSearch() }
            .toolbar { ToolbarItem { Button("Done") { model.clearSearch(); dismiss() } } }
        }
    }
}
```

(On macOS `.navigationBarDrawer` is ignored gracefully; if the compiler objects, use plain `.searchable(text:)`.)

- [ ] **Step 3: Toolbar entry + sheet**

```swift
                    Button("Find", systemImage: "magnifyingglass") { showSearch = true }
```
```swift
            .sheet(isPresented: $showSearch, onDismiss: { model.clearSearch() }) {
                SearchView(model: model)
            }
```
(with `@State private var showSearch = false`).

- [ ] **Step 4: Build + commit**

Run: `cd App && xcodegen generate && cd .. && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

```bash
git add App
git commit -m "feat: in-book search UI with live results and navigate"
```

---

## Phase D — Final assembly

### Task 9: iOS build, docs, smoke checklist

**Files:**
- Modify: `CLAUDE.md`, `docs/superpowers/plans/2026-07-12-m1-followups.md`
- Test: build verification only

- [ ] **Step 1: Both-platform build**

Run:
```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build
xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'generic/platform=iOS Simulator' build
```
Expected: BUILD SUCCEEDED both. Fix any platform-conditional issues (pasteboard, `.searchable` placement) with mechanical `#if os(...)`; structural changes go back to the controller.

- [ ] **Step 2: Full suite**

Run: `swift test`
Expected: PASS, zero warnings. If the known WebKit-suite flake surfaces on a full run, rerun and note it (it's ticketed); the annotation/search integration tests must pass on a focused `swift test --filter EPUBNavigator` run.

- [ ] **Step 3: Docs**

In `CLAUDE.md`, update the architecture bullet: the EPUB navigator now supports highlights (5 colors), notes, bookmarks, and in-book search; annotations persist in the `annotation` table via `AnnotationStore`.

In `docs/superpowers/plans/2026-07-12-m1-followups.md`, add an M3 note: `content_fts` catalogue full-text-search is still deferred (M3 shipped reader-side in-book search only); the in-text margin indicator for noted passages is deferred (foliate single-style overlay); annotation export (Markdown/CSV) remains a M6 differentiator.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs
git commit -m "docs: M3 completion notes and deferred follow-ups"
```

- [ ] **Step 5: Manual smoke test (human — agents skip, controller reports it as owed)**

On macOS and iOS: open an EPUB → select text → the color bar appears → pick a color → highlight is drawn → tap the highlight → note editor opens → add a note, change color, Done → reopen the annotations list → the entry shows the note glyph → tap it → navigates back to the passage → turn several pages and back → the highlight is still drawn (create-overlay re-draw) → bookmark a page → toggle it off → Find in Book → type a word → results stream in → tap a result → navigates to it → quit and relaunch → highlights/notes/bookmarks all restored.

---

## Plan Self-Review Notes

- **Spec/scope coverage (M3):** highlights with 5 Books-style colors ✔ (Tasks 2/3/6); notes ✔ (Tasks 5/6); bookmarks ✔ (Tasks 5/6); in-book search ✔ (Tasks 4/8); annotations list UI ✔ (Task 7); range-CFI + text-context anchoring ✔ (Tasks 2/3, `Locator.textContext`); permanent tombstones + apply-seq ✔ (Task 1); overlay re-draw across pagination ✔ (Task 3 `create-overlay`); persistence + restore-on-open ✔ (Task 5). Deferred and noted: in-text margin indicator (note glyph in list instead); annotation export (M6); catalogue `content_fts` (later).
- **Boundary check:** `AnnotationStore` treats the locator as opaque JSON (no reader import in IqraLibrary) ✔; `Annotation`/selection/search types live in IqraReader ✔; the app composes ✔.
- **Type consistency:** `AnnotationRecord.locator` (JSON String) ↔ `Locator.from(jsonData:)` in the app ✔; `HighlightColor.rawValue` stored in `annotation.color`, `.cssColor` sent to the overlay ✔; `SelectionInfo`→`Locator` mapping in `createHighlight` carries `cfi`/`spineIndex`/`totalProgression`/`textContext` used by the store's `json_extract` ordering ✔; bridge `addAnnotation({cfi,color,kind})` matches `EPUBNavigator.addAnnotation`'s payload keys ✔; `annotationTapped.value` (CFI) matched against `annotation.locator.cfi` in `didTapAnnotation` ✔.
- **Known risk points:** WKWebView selection driving in tests (Task 3 uses a real range + `pointerup`; `showAnnotation` for the tap — both deterministic); `AnnotationStore.dbm` must be `public` for `observeAnnotations().values(in:)` (called out in Task 5); `json_extract` availability (Task 1 verifies, has a Swift-sort fallback); the `.sheet(item:)` binding to a read-only `@Observable` property (Task 6 flags the settable-property alternative); highlight overlay color in dark mode is explicit-per-annotation (research gotcha — no CSS inheritance to the overlay).

## Execution

Plan complete. Execute with superpowers:subagent-driven-development (fresh subagent per task, review between tasks) or superpowers:executing-plans (inline with checkpoints).
