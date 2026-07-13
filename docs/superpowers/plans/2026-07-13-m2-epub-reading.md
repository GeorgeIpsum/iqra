# M2 — EPUB Reading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open an EPUB from the library and read it — paginated foliate-js rendering in WKWebView on macOS and iOS, reading position that persists and restores, appearance settings (theme/font/size/spacing), plus the four Early-M2 hardening items ticketed by M1's final review.

**Architecture:** Phase A (Tasks 1–4) hardens M1 seams (import_item lifecycle, sidecar reconciliation, thumbnail backfill, off-main import). Phase B (Tasks 5–11) adds the `IqraReader` target: vendored foliate-js served alongside book resources by a `WKURLSchemeHandler` (one custom scheme, unique host per book), a Swift↔JS bridge speaking a small JSON message protocol, a composite `Locator` model persisted to the existing `reading_state` table, and a SwiftUI reader screen wired into the app. Spec: `docs/superpowers/specs/2026-07-11-iqra-architecture-design.md` ("The reflowable-text engine"); tickets: `docs/superpowers/plans/2026-07-12-m1-followups.md`.

**Tech Stack:** Swift 5.10, WKWebView (WebKit), foliate-js (MIT, vendored), GRDB 7, SwiftUI, XcodeGen.

## Global Constraints

- Deployment floors: **iOS 17.0 / macOS 14.0**. Swift tools **5.10**.
- Runtime Swift dependencies remain **GRDB.swift + ZIPFoundation only**. foliate-js is vendored source (MIT — keep its LICENSE file), never an npm/build step.
- Package boundaries (spec "System overview"): `IqraCore` imports Foundation only. `IqraLibrary` never imports UI or reader code. **`IqraReader` may import IqraCore + WebKit but NEVER IqraLibrary** — persistence flows through protocols/closures the app wires up.
- Every `Archive(...)` (ZIPFoundation) call passes `pathEncoding: nil` (selects the non-deprecated throwing initializer).
- Security (spec): custom scheme `iqra-book://<bookUUID>/...` with a **unique host per book**; strict CSP injected on every HTML response; `WKContentRuleList` blocks all network loads except the custom scheme; publisher scripts never execute (foliate-js loads EPUB documents with scripting off).
- Locator JSON is the composite record from the spec: `{ spineHref, cfi, textContext?, progressionInChapter, totalProgression }` — point CFI for positions. `totalProgression` is display/fallback only, never an anchor.
- Reading state writes go through the existing `reading_state` table: per (book, format), `currentLocator` JSON, `highWaterMark` merged by **max**, apply-sequence stamped.
- All package tests headless via `swift test` on macOS; zero-warning builds. WKWebView integration tests live in the package test target (macOS host) — if a WebKit test proves environment-flaky, it may be marked `XCTSkip` on CI-less environments ONLY with a comment and a note in the task report; the app smoke test then covers it.
- Commit per task, conventional-commit subjects.

## File Structure

```
Package.swift                                    — add IqraReader target (+ resources) & test target
Sources/IqraReader/
  Vendor/foliate-js/…                            — vendored modules (view.js, epub.js, epubcfi.js, paginator.js, …) + LICENSE
  Resources/reader.html                          — host page: imports vendor modules + bridge.js
  Resources/bridge.js                            — our glue: open book, events → webkit.messageHandlers, commands
  Locator.swift                                  — composite Locator (Codable) + ReaderTheme/ReaderSettings value types
  BookResourceSchemeHandler.swift                — WKURLSchemeHandler: serves reader.html, vendor JS, book bytes
  EPUBNavigator.swift                            — WKWebView owner: bridge protocol, goTo, settings, relocate events
  NavigatorProtocols.swift                       — Navigator base protocol (spec: protocol composition; capability protocols arrive with their features)
Sources/IqraLibrary/
  Database/ReadingStateStore.swift               — GRDB CRUD for reading_state (locator get/set, high-water max)
  Import/ImportPipeline.swift                    — (Task 1) bookmark param; (Task 4) streaming hash
  Import/ReconciliationSweep.swift               — (Tasks 1–3) phases 4–6
  Database/LibraryStore.swift                    — (Task 1) recovery query incl. 'pending'; (Task 10) openableFormat(bookID:)
Tests/IqraReaderTests/
  LocatorTests.swift
  SchemeHandlerTests.swift                       — pure resolver tests (no WebKit)
  EPUBNavigatorTests.swift                       — WKWebView integration on macOS host
Tests/IqraLibraryTests/…                         — extended per task
App/Sources/ReaderScreen.swift                   — SwiftUI screen hosting EPUBNavigator + chrome
App/Sources/ReaderSettingsStore.swift            — appearance persistence (UserDefaults) — app-owned
App/Sources/LibraryView.swift / LibraryViewModel.swift — (Tasks 4, 10) open-book wiring, async import
```

---

## Phase A — Early-M2 hardening (from M1 final review)

### Task 1: import_item crash/pending lifecycle + security-scoped bookmarks

**Files:**
- Modify: `Sources/IqraLibrary/Import/ImportPipeline.swift` (upsert gains bookmark; importFile accepts bookmark data)
- Modify: `Sources/IqraLibrary/Import/ReconciliationSweep.swift` (phase 4)
- Modify: `Sources/IqraLibrary/Database/LibraryStore.swift:182-191` (recovery query includes 'pending')
- Modify: `App/Sources/LibraryViewModel.swift` (pass bookmarks on import)
- Test: `Tests/IqraLibraryTests/ImportPipelineTests.swift`, `Tests/IqraLibraryTests/ReconciliationSweepTests.swift`, `Tests/IqraLibraryTests/LibraryStoreTests.swift`

**Interfaces:**
- Consumes: existing `ImportPipeline.importFile(at:resolution:)`, `upsertImportItem` (private), `SweepReport`, `LibraryStore.quarantinedItems()`.
- Produces:

```swift
// ImportPipeline
public func importFile(at url: URL, resolution: IdentifierResolution = .ask,
                       sourceBookmark: Data? = nil) throws -> ImportResult
// SweepReport gains:
public var staleImportsFailed = 0
// LibraryStore — recovery query now returns pending too:
public func recoveryItems() throws -> [ImportItemRecord]   // status IN (quarantined, failed, pending)
// quarantinedItems() remains but delegates to recoveryItems() (deprecated comment, kept for source compat)
```

- [ ] **Step 1: Write the failing tests**

Append to `Tests/IqraLibraryTests/ImportPipelineTests.swift`:

```swift
    func testSourceBookmarkIsPersistedOnImportItem() throws {
        let epub = try Fixtures.makeEPUB(title: "BM", author: "A", isbn: nil, dir: dir)
        let fakeBookmark = Data("bookmark-bytes".utf8)
        _ = try pipeline.importFile(at: epub, sourceBookmark: fakeBookmark)
        let stored = try dbm.writer.read { db in
            try Data.fetchOne(db, sql: "SELECT sourceBookmark FROM import_item WHERE sourceDisplayPath = ?",
                              arguments: [epub.path])
        }
        XCTAssertEqual(stored, fakeBookmark)
    }
```

Append to `Tests/IqraLibraryTests/ReconciliationSweepTests.swift`:

```swift
    func testStaleImportingRowsAreMarkedFailedBySweep() throws {
        // simulate a crash mid-import: row left at 'importing'
        let epub = try Fixtures.makeEPUB(title: "Stale", author: "A", isbn: nil, dir: dir)
        pipeline.failpoint = .afterStaging
        XCTAssertThrowsError(try pipeline.importFile(at: epub))
        let importing = try dbm.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM import_item WHERE status = 'importing'")!
        }
        XCTAssertEqual(importing, 1)

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm)
        XCTAssertEqual(report.staleImportsFailed, 1)
        let row = try dbm.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT status, message FROM import_item")!
        }
        XCTAssertEqual(row["status"] as String, "failed")
        XCTAssertNotNil(row["message"] as String?)
    }
```

Append to `Tests/IqraLibraryTests/LibraryStoreTests.swift`:

```swift
    func testRecoveryItemsIncludePendingRows() throws {
        try dbm.writer.write { db in
            for (id, status) in [("a", "pending"), ("b", "quarantined"), ("c", "failed"), ("d", "done")] {
                try ImportItemRecord(id: id, sourceBookmark: nil, sourceDisplayPath: "/x/\(id).epub",
                                     status: status, rejection: nil, message: nil, attemptCount: 1,
                                     createdAt: Date(), updatedAt: Date(), bookId: nil).insert(db)
            }
        }
        XCTAssertEqual(Set(try store.recoveryItems().map(\.id)), ["a", "b", "c"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter testSourceBookmarkIsPersistedOnImportItem && swift test --filter testStaleImportingRowsAreMarkedFailedBySweep && swift test --filter testRecoveryItemsIncludePendingRows`
Expected: FAIL — no `sourceBookmark:` parameter / no `staleImportsFailed` / no `recoveryItems`.

- [ ] **Step 3: Implement**

In `Sources/IqraLibrary/Import/ImportPipeline.swift`:
- `importFile` signature becomes `public func importFile(at url: URL, resolution: IdentifierResolution = .ask, sourceBookmark: Data? = nil) throws -> ImportResult`; the initial upsert passes the bookmark through.
- `upsertImportItem` gains `bookmark: Data? = nil` and binds it instead of the literal NULL, preserving it on conflict:

```swift
    private func upsertImportItem(id: String, path: String, status: String,
                                  rejection: ImportRejection?, bookId: String?,
                                  message: String? = nil, bookmark: Data? = nil) throws {
        try dbm.writer.write { db in
            try db.execute(sql: """
                INSERT INTO import_item (id, sourceBookmark, sourceDisplayPath, status, rejection,
                                         message, attemptCount, createdAt, updatedAt, bookId)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET status = excluded.status,
                    rejection = excluded.rejection, message = excluded.message,
                    sourceBookmark = COALESCE(excluded.sourceBookmark, import_item.sourceBookmark),
                    updatedAt = excluded.updatedAt, bookId = excluded.bookId
                """, arguments: [id, bookmark, path, status, rejection?.rawValue, message, Date(), Date(), bookId])
        }
    }
```

(Only the first call site — the initial "importing" upsert — passes `bookmark: sourceBookmark`; later status updates pass nothing and COALESCE preserves it.)

In `Sources/IqraLibrary/Import/ReconciliationSweep.swift`, add phase 4 before `return report` and the field on `SweepReport`:

```swift
    /// Rows whose import was cut off by a crash and marked 'failed' by this sweep.
    public var staleImportsFailed = 0
```

```swift
        // 4. import_item rows stuck at 'importing' can only mean a crash mid-import
        //    (every live code path ends in a terminal status or 'pending'). Mark them
        //    failed so the recovery UI can offer a retry via the stored bookmark.
        do {
            let stale = try dbm.writer.write { db in
                try Int.fetchOne(db, sql: """
                    UPDATE import_item
                    SET status = 'failed', message = 'Interrupted by a crash or forced quit',
                        updatedAt = ?
                    WHERE status = 'importing'
                    RETURNING count(*) OVER ()
                    """, arguments: [Date()]) ?? 0
            }
            report.staleImportsFailed = stale
        } catch {
            report.failures += 1
        }
```

(If `RETURNING count(*) OVER ()` proves unsupported by the shipped SQLite, use `db.changes` — GRDB exposes `db.changesCount` after `execute` — the implementer picks whichever compiles and asserts the same behavior.)

In `Sources/IqraLibrary/Database/LibraryStore.swift`, replace `quarantinedItems()`:

```swift
    /// Items the recovery UI surfaces: quarantined (DRM/unsupported/corrupt), failed
    /// (real errors or crash-interrupted imports), and pending (identifier matches the
    /// user never resolved — e.g. the app quit with the prompt queued).
    public func recoveryItems() throws -> [ImportItemRecord] {
        try dbm.writer.read { db in
            try ImportItemRecord
                .filter(["quarantined", "failed", "pending"].contains(Column("status")))
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    /// Deprecated spelling kept for source compatibility; use `recoveryItems()`.
    public func quarantinedItems() throws -> [ImportItemRecord] { try recoveryItems() }
```

In `App/Sources/LibraryViewModel.swift` `importFiles`, create and pass the bookmark (best-effort — a failure to mint a bookmark must not block the import):

```swift
                let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil, relativeTo: nil)
                let result = try pipeline.importFile(at: url, sourceBookmark: bookmark)
```

(iOS has no `.withSecurityScope`; wrap in `#if os(macOS)` and use `url.bookmarkData()` plain on iOS.)

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter ImportPipelineTests && swift test --filter ReconciliationSweepTests && swift test --filter LibraryStoreTests`
Expected: PASS (all, including the three new tests). Existing crash-simulation tests still pass: phase 4 runs at *sweep* time, not import time, so the crash tests' in-run expectations are untouched — but `testCleansStagingLeftovers` also asserts on sweep output; verify it still passes (its import_item row now flips to failed during the sweep, which that test does not assert against).

- [ ] **Step 5: Full suite + build the app**

Run: `swift test && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build`
Expected: PASS + BUILD SUCCEEDED (view model changed).

- [ ] **Step 6: Commit**

```bash
git add Sources Tests App
git commit -m "feat: import_item crash recovery, pending rows in recovery UI, source bookmarks"
```

---

### Task 2: Sweep reconciles sidecar-ahead-of-DB formats, .partial cleanup, adoption dedupe

**Files:**
- Modify: `Sources/IqraLibrary/Import/ReconciliationSweep.swift`
- Test: `Tests/IqraLibraryTests/ReconciliationSweepTests.swift`

**Interfaces:**
- Consumes: `Sidecar`, `FormatRecord`, `paths.formatFile/bookDir/metadataSidecar`, `ImportPipeline` failpoints (`.afterAttachFileMove`, `.afterAttachSidecar`).
- Produces on `SweepReport`: `public var formatsAdoptedForKnownBooks = 0`, `public var partialsDeleted = 0`, `public var orphansSkippedAsDuplicates = 0`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/IqraLibraryTests/ReconciliationSweepTests.swift`:

```swift
    func testSweepAdoptsSidecarFormatsForKnownBooks() throws {
        // attach crash after the sidecar write: sidecar lists a format the DB doesn't know
        let first = try Fixtures.makeEPUB(title: "Known", author: "A", isbn: "9991112223334", dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: first) else { return XCTFail() }
        let second = try Fixtures.makeEPUB(title: "Known Two", author: "A", isbn: "9991112223334", dir: dir)
        pipeline.failpoint = .afterAttachSidecar
        XCTAssertThrowsError(try pipeline.importFile(at: second, resolution: .attach(toBook: bookID)))
        pipeline.failpoint = nil
        XCTAssertEqual(try store.fetchFormats(bookID: bookID).count, 1) // DB behind sidecar

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm)
        XCTAssertEqual(report.formatsAdoptedForKnownBooks, 1)
        let formats = try store.fetchFormats(bookID: bookID)
        XCTAssertEqual(formats.count, 2)
        // adopted format is present (its file was written before the sidecar)
        let adopted = formats.first { $0.originalFileName == second.lastPathComponent }
        XCTAssertNotNil(adopted)
        // idempotent
        XCTAssertEqual(try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm)
            .formatsAdoptedForKnownBooks, 0)
    }

    func testSweepDeletesStalePartialFiles() throws {
        let epub = try Fixtures.makeEPUB(title: "P", author: "A", isbn: nil, dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else { return XCTFail() }
        let stale = paths.bookDir(bookID).appendingPathComponent("\(UUID().uuidString).epub.partial")
        try Data("half".utf8).write(to: stale)

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm)
        XCTAssertEqual(report.partialsDeleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testOrphanAdoptionSkipsDuplicateContentHash() throws {
        // book already in the DB; an orphan folder re-describes the same bytes under a new bookID
        let epub = try Fixtures.makeEPUB(title: "Dup", author: "A", isbn: nil, dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else { return XCTFail() }
        let format = try XCTUnwrap(store.fetchFormats(bookID: bookID).first)
        let orphanID = UUID()
        let orphanDir = paths.bookDir(orphanID)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let sidecar = Sidecar(bookID: orphanID,
                              metadata: ExtractedMetadata(title: "Dup", titleSort: "Dup", language: "en",
                                                          publisher: nil, bookDescription: nil,
                                                          contributors: [], identifiers: []),
                              formats: [.init(formatID: UUID(), formatType: .epub,
                                              originalFileName: "dup.epub", byteSize: format.byteSize,
                                              contentHash: format.contentHash)],
                              applySeq: 0)
        try Sidecar.write(sidecar, to: orphanDir.appendingPathComponent("metadata.json"))

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm)
        XCTAssertEqual(report.orphansAdopted, 0)
        XCTAssertEqual(report.orphansSkippedAsDuplicates, 1)
        XCTAssertEqual(try dbm.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM book")! }, 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ReconciliationSweepTests`
Expected: FAIL — missing `formatsAdoptedForKnownBooks` / `partialsDeleted` / `orphansSkippedAsDuplicates`.

- [ ] **Step 3: Implement**

In `Sources/IqraLibrary/Import/ReconciliationSweep.swift`:

Add the three fields to `SweepReport`:

```swift
    /// Formats found in a known book's sidecar but absent from the DB (attach-crash window).
    public var formatsAdoptedForKnownBooks = 0
    /// Stale .partial temp files removed from book folders.
    public var partialsDeleted = 0
    /// Orphan folders skipped because their content already exists under another book.
    public var orphansSkippedAsDuplicates = 0
```

In phase 2, change the known-book `continue` into sidecar reconciliation, and add the hash check before adoption. Replace the phase-2 folder loop body with:

```swift
            for folder in folders where folder.lastPathComponent != ".staging" {
                let name = folder.lastPathComponent
                if knownBookIDs.contains(name) {
                    // Known book: the attach path writes file+sidecar before the DB row, so a
                    // crash can leave the sidecar ahead of the DB. Adopt the missing formats.
                    do {
                        report.formatsAdoptedForKnownBooks +=
                            try adoptMissingFormats(inFolder: folder, bookIDString: name, dbm: dbm)
                    } catch {
                        report.failures += 1
                    }
                    continue
                }
                guard let sidecar = try? Sidecar.read(from: folder.appendingPathComponent("metadata.json")),
                      let firstFormat = sidecar.formats.first else { continue } // undescribed folder: leave for the user
                // Adoption must respect the dedupe ladder's identity rule: identical bytes
                // already catalogued under another book means this orphan is a leftover from
                // a retried import, not a new book. Skip it (files stay on disk untouched).
                let hashes = sidecar.formats.map(\.contentHash)
                let duplicate = try dbm.writer.read { db in
                    try Int.fetchOne(db, sql: """
                        SELECT count(*) FROM format f JOIN book b ON b.id = f.bookId
                        WHERE f.contentHash IN (\(hashes.map { _ in "?" }.joined(separator: ",")))
                          AND f.deleted = 0 AND b.deleted = 0
                        """, arguments: StatementArguments(hashes))! > 0
                }
                if duplicate {
                    report.orphansSkippedAsDuplicates += 1
                    continue
                }
                do {
                    // (existing adoption body unchanged: insertBook + dropFirst() loop)
```

Add the helper (same file, inside the enum below `run`):

```swift
    /// Inserts format + format_local rows for sidecar entries a known book's DB is missing.
    /// Returns how many were adopted.
    private static func adoptMissingFormats(inFolder folder: URL, bookIDString: String,
                                            dbm: DatabaseManager) throws -> Int {
        guard let sidecar = try? Sidecar.read(from: folder.appendingPathComponent("metadata.json"))
        else { return 0 }
        let known: Set<String> = try dbm.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM format WHERE bookId = ?",
                                    arguments: [bookIDString]))
        }
        var adopted = 0
        for entry in sidecar.formats where !known.contains(entry.formatID.uuidString) {
            let file = folder.appendingPathComponent(
                "\(entry.formatID.uuidString).\(entry.formatType.fileExtension)")
            let present = FileManager.default.fileExists(atPath: file.path)
            try dbm.writer.write { db in
                let seq = try dbm.nextApplySequence(db)
                try FormatRecord(id: entry.formatID.uuidString, bookId: bookIDString,
                                 formatType: entry.formatType.rawValue,
                                 originalFileName: entry.originalFileName, byteSize: entry.byteSize,
                                 contentHash: entry.contentHash, addedAt: Date(),
                                 applySeq: seq, deleted: false).insert(db)
                try db.execute(sql: """
                    INSERT INTO format_local (formatId, present, localVerifiedAt, missing)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [entry.formatID.uuidString, present, present ? Date() : nil, !present])
            }
            adopted += 1
        }
        return adopted
    }
```

Add phase 5 (partial cleanup) after phase 3, before phase 4 from Task 1 or after — order among 3/4/5 is not semantically coupled; keep numbering by insertion order and renumber comments:

```swift
        // 5. stale ".partial" temp files (hydrate/attach copies interrupted mid-write):
        //    the completed file either replaced them or never will; both ways they're dead.
        if let folders = try? fm.contentsOfDirectory(at: paths.booksDir, includingPropertiesForKeys: nil) {
            for folder in folders where folder.lastPathComponent != ".staging" {
                guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                else { continue }
                for file in files where file.lastPathComponent.hasSuffix(".partial") {
                    do {
                        try fm.removeItem(at: file)
                        report.partialsDeleted += 1
                    } catch {
                        report.failures += 1
                    }
                }
            }
        }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter ReconciliationSweepTests`
Expected: PASS (all, including the three new tests and prior ones — the known-book reconciliation must not disturb `testAdoptsOrphanFolderFromSidecar`'s idempotency assertion).

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/IqraLibrary/Import Tests/IqraLibraryTests
git commit -m "feat: sweep reconciles attach-crash leftovers, stale partials, duplicate orphans"
```

---

### Task 3: Thumbnail backfill (sweep + coverURL fallback)

**Files:**
- Modify: `Sources/IqraLibrary/Import/ReconciliationSweep.swift` (adoption runs ThumbnailPipeline; signature gains caches)
- Modify: `App/Sources/LibraryViewModel.swift:52-56` (cover fallback)
- Test: `Tests/IqraLibraryTests/ReconciliationSweepTests.swift`

**Interfaces:**
- Consumes: `ThumbnailPipeline.process(coverData:bookID:paths:caches:) -> ThumbnailResult`, `LibraryPaths.cover(bookID:)`, `Caches.thumbnail(bookID:size:)`.
- Produces: **breaking signature change** `ReconciliationSweep.run(paths:store:dbm:caches:)` — update ALL call sites (tests use a shared helper; `App/Sources/LibraryViewModel.swift:43`).

- [ ] **Step 1: Write the failing test**

Append to `Tests/IqraLibraryTests/ReconciliationSweepTests.swift` (and add a `caches` property to the fixture setup mirroring `ImportPipelineTests`; pass it at every existing `ReconciliationSweep.run` call):

```swift
    func testAdoptedOrphanGetsThumbnailsBackfilled() throws {
        let epub = try Fixtures.makeEPUB(title: "Thumb", author: "A", isbn: nil,
                                         coverJPEG: Fixtures.tinyJPEG(), dir: dir)
        pipeline.failpoint = .afterRename  // crash BEFORE ThumbnailPipeline ran
        XCTAssertThrowsError(try pipeline.importFile(at: epub))
        pipeline.failpoint = nil

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
        XCTAssertEqual(report.orphansAdopted, 1)
        let bookID = try XCTUnwrap(try dbm.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM book")
        }).flatMap(UUID.init(uuidString:)) ?? UUID()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: caches.thumbnail(bookID: bookID, size: .grid).path))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReconciliationSweepTests`
Expected: FAIL — `run` has no `caches:` parameter (compile error across the test file after adding it to one call is fine; fix all call sites in this step).

- [ ] **Step 3: Implement**

`ReconciliationSweep.run(paths:store:dbm:caches:)` — after a successful orphan adoption (inside the same `do` block, after `report.orphansAdopted += 1`):

```swift
                    // Backfill thumbnails: the crash window fires before ThumbnailPipeline ran,
                    // so the folder has cover.jpg but Caches has nothing. Best-effort — a
                    // corrupt cover must not fail the adoption that already committed.
                    if let coverData = try? Data(contentsOf: folder.appendingPathComponent("cover.jpg")) {
                        _ = try? ThumbnailPipeline.process(coverData: coverData, bookID: sidecar.bookID,
                                                           paths: paths, caches: caches)
                    }
```

`App/Sources/LibraryViewModel.swift`: pass `caches:` at the `ReconciliationSweep.run` call, and make `coverURL(for:)` fall back to the book folder's cover (Caches purge recovery):

```swift
    func coverURL(for bookID: UUID) -> URL? {
        guard let caches, let paths else { return nil }
        let thumb = caches.thumbnail(bookID: bookID, size: .grid)
        if FileManager.default.fileExists(atPath: thumb.path) { return thumb }
        let cover = paths.cover(bookID: bookID)
        return FileManager.default.fileExists(atPath: cover.path) ? cover : nil
    }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter ReconciliationSweepTests`
Expected: PASS.

- [ ] **Step 5: Full suite + app build**

Run: `swift test && cd App && xcodegen generate && cd .. && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build`
Expected: PASS + BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests App
git commit -m "feat: thumbnail backfill on adoption and cover fallback after cache purge"
```

---

### Task 4: Off-main-actor import + streaming SHA-256

**Files:**
- Modify: `Sources/IqraLibrary/Import/ImportPipeline.swift:19-22` (streaming hash), class becomes `@unchecked Sendable` with a documented single-caller contract
- Modify: `App/Sources/LibraryViewModel.swift:58-81` (detached import)
- Test: `Tests/IqraLibraryTests/ImportPipelineTests.swift`

**Interfaces:**
- Consumes: CryptoKit `SHA256` incremental API.
- Produces: `public func sha256Hex(of url: URL) throws -> String` (same signature, streaming implementation); `ImportPipeline: @unchecked Sendable`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/IqraLibraryTests/ImportPipelineTests.swift`:

```swift
    func testSha256HexStreamsLargeFilesCorrectly() throws {
        // 4 MiB of a repeating pattern — larger than the 1 MiB chunk size, exercising
        // multi-chunk accumulation. Compare against the one-shot digest.
        var data = Data()
        let block = Data((0..<1024).map { UInt8($0 % 251) })
        for _ in 0..<(4 * 1024) { data.append(block) }
        let url = dir.appendingPathComponent("big.bin")
        try data.write(to: url)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try sha256Hex(of: url), expected)
    }
```

(Needs `import CryptoKit` at the top of the test file.)

- [ ] **Step 2: Run test to verify it fails or trivially passes**

Run: `swift test --filter testSha256HexStreamsLargeFilesCorrectly`
Expected: PASS against the current whole-file implementation (this is a pin-the-behavior test). That is acceptable here — the test exists to catch the rewrite breaking equivalence. Note it in the commit message.

- [ ] **Step 3: Rewrite sha256Hex as streaming + mark the pipeline Sendable**

```swift
/// Streams the file through SHA-256 in 1 MiB chunks — imports of multi-hundred-MB files
/// must not materialize the whole file in memory.
public func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
```

```swift
/// Thread-safety contract: ImportPipeline is stateless between calls except the test-only
/// `failpoint` hook; all shared state lives in GRDB (serialized writer) and the filesystem
/// (unique staging dirs per import). Callers must not run two imports of the SAME source
/// path concurrently; the app serializes batches (one Task, sequential loop).
extension ImportPipeline: @unchecked Sendable {}
```

`App/Sources/LibraryViewModel.swift` — move the import loop off the MainActor; only UI-state mutation hops back:

```swift
    func importFiles(_ urls: [URL]) async {
        guard let pipeline, let store else {
            lastError = "The library isn't ready yet. Please try again in a moment."
            return
        }
        var batchErrors: [String] = []
        var conflicts: [(sourceURL: URL, existingBookID: UUID)] = []
        // Import work is CPU+IO heavy (copy, hash, unzip): run the batch off the MainActor.
        await Task.detached(priority: .userInitiated) {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                #if os(macOS)
                let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil, relativeTo: nil)
                #else
                let bookmark = try? url.bookmarkData()
                #endif
                do {
                    let result = try pipeline.importFile(at: url, sourceBookmark: bookmark)
                    if case let .needsUserDecision(existingBookID) = result {
                        conflicts.append((url, existingBookID))
                    }
                } catch {
                    batchErrors.append("Import failed for \(url.lastPathComponent): \(error)")
                }
            }
        }.value
        pendingIdentifierMatches.append(contentsOf: conflicts)
        if !batchErrors.isEmpty {
            importErrors.append(contentsOf: batchErrors)
            lastError = importErrors.joined(separator: "\n")
        }
        quarantined = (try? store.recoveryItems()) ?? quarantined
    }
```

Note for the implementer: `batchErrors`/`conflicts` captured mutably inside `Task.detached` will trip strict-concurrency diagnostics if the target enables them; if the compiler objects, have the detached closure RETURN `(errors: [String], conflicts: [(URL, UUID)])` and destructure after `await …value` instead of capturing — same behavior, cleaner isolation. Also update the `quarantined` refresh to `recoveryItems()` (Task 1 renamed it) and rename the view model property `quarantined`→ keep as-is (UI copy unchanged).

- [ ] **Step 4: Run tests + build**

Run: `swift test && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build`
Expected: PASS + BUILD SUCCEEDED, zero warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests App
git commit -m "perf: streaming SHA-256 and off-main-actor batch import"
```

---

## Phase B — The reader engine

**Recorded spec deviation (justified):** the spec sketched "unzipped on demand via ZIPFoundation" resource serving. foliate-js's actual architecture (verified against upstream source, commit `78914ae`) parses the EPUB in-page with its vendored zip.js and re-serves every intra-book resource as `blob:` object URLs — the host only delivers the single `.epub` byte stream plus the reader page/JS. So the scheme handler serves whole files from one origin (the pattern every shipping embedder uses), and ZIPFoundation plays no role in rendering. The spec's security posture (custom scheme, per-book origin, CSP, no localhost server) is unchanged.

**Known platform constraint:** WKWebView custom schemes are NOT secure contexts → `crypto.subtle` is undefined in page JS → foliate-js's default IDPF font-deobfuscation breaks. Mitigation (implemented in Task 7's bridge): construct the EPUB book object ourselves with a pure-JS SHA-1 passed to `new EPUB({loadText, loadBlob, getSize, sha1})`, instead of relying on `view.open(file)`'s internal path.

### Task 5: IqraReader target, vendored foliate-js, Locator model

**Files:**
- Modify: `Package.swift`
- Create: `Sources/IqraReader/Vendor/foliate-js/` (vendored files + LICENSE), `Sources/IqraReader/Locator.swift`
- Test: `Tests/IqraReaderTests/LocatorTests.swift`

**Interfaces:**
- Consumes: IqraCore (`FormatType`).
- Produces:

```swift
// Sources/IqraReader/Locator.swift  (IqraReader — the reading-position vocabulary)
public struct Locator: Codable, Equatable, Sendable {
    public var spineIndex: Int
    public var spineHref: String?
    public var cfi: String?                  // point or range CFI; the precise coordinate
    public var progressionInChapter: Double? // display only
    public var totalProgression: Double      // display/fallback only, never an anchor
    public var tocLabel: String?
    public init(spineIndex:spineHref:cfi:progressionInChapter:totalProgression:tocLabel:)
    public func jsonData() throws -> Data
    public static func from(jsonData: Data) throws -> Locator
}
public struct ReaderTheme: Codable, Equatable, Sendable {
    public var background: String   // CSS color, e.g. "#ffffff"
    public var foreground: String
    public static let light: ReaderTheme;  public static let sepia: ReaderTheme;  public static let dark: ReaderTheme
}
public struct ReaderSettings: Codable, Equatable, Sendable {
    public var fontSizePercent: Int      // 100 = publisher default
    public var fontFamily: String?       // nil = publisher fonts
    public var lineHeight: Double        // e.g. 1.4
    public var justify: Bool
    public var theme: ReaderTheme
    public var flow: Flow
    public enum Flow: String, Codable, Sendable { case paginated, scrolled }
    public static let `default`: ReaderSettings
}
```

- [ ] **Step 1: Add the target to Package.swift**

Add to `products`: `.library(name: "IqraReader", targets: ["IqraReader"])`. Add to `targets`:

```swift
        .target(
            name: "IqraReader",
            dependencies: ["IqraCore"],
            resources: [
                .copy("Vendor"),
                .copy("Resources"),
            ]
        ),
        .testTarget(name: "IqraReaderTests", dependencies: ["IqraReader"]),
```

(`Resources/` is created in Task 7; create an empty `Sources/IqraReader/Resources/.gitkeep` now so the manifest resolves — replace `.gitkeep` when reader.html lands, or defer the `.copy("Resources")` line to Task 7; implementer's choice, note it.)

- [ ] **Step 2: Vendor foliate-js at the pinned commit**

foliate-js is MIT, no releases; upstream README mandates pinning. Vendor exactly these files at commit `78914ae` (the minimum static+dynamic import graph for reflowable + fixed-layout EPUB, plus search.js which view.js dynamically imports on first use — M3 needs it and a missing dynamic import fails at runtime):

```bash
mkdir -p Sources/IqraReader/Vendor/foliate-js/vendor
PIN=78914ae
BASE=https://raw.githubusercontent.com/johnfactotum/foliate-js/$PIN
for f in view.js paginator.js epub.js epubcfi.js progress.js overlayer.js \
         text-walker.js fixed-layout.js search.js LICENSE; do
  curl -fsSL "$BASE/$f" -o "Sources/IqraReader/Vendor/foliate-js/$f"
done
curl -fsSL "$BASE/vendor/zip.js" -o "Sources/IqraReader/Vendor/foliate-js/vendor/zip.js"
echo "foliate-js pinned at johnfactotum/foliate-js@$PIN (MIT). Do not edit vendored files." \
  > Sources/IqraReader/Vendor/foliate-js/PINNED.txt
```

If any file 404s at that commit path (upstream may have moved something), STOP and report BLOCKED with the failing URL — do not substitute a different commit silently.

- [ ] **Step 3: Write the failing test**

```swift
// Tests/IqraReaderTests/LocatorTests.swift
import XCTest
import IqraReader

final class LocatorTests: XCTestCase {
    func testLocatorJSONRoundTrip() throws {
        let locator = Locator(spineIndex: 4, spineHref: "OEBPS/ch4.xhtml",
                              cfi: "epubcfi(/6/10!/4/2/8,/1:5,/1:25)",
                              progressionInChapter: 0.31, totalProgression: 0.42,
                              tocLabel: "Chapter Four")
        let data = try locator.jsonData()
        XCTAssertEqual(try Locator.from(jsonData: data), locator)
    }

    func testDefaultSettings() {
        let s = ReaderSettings.default
        XCTAssertEqual(s.fontSizePercent, 100)
        XCTAssertEqual(s.flow, .paginated)
        XCTAssertEqual(s.theme, .light)
    }

    func testVendoredFoliateIsBundled() throws {
        let url = Bundle.module.url(forResource: "Vendor/foliate-js/view", withExtension: "js")
        XCTAssertNotNil(url, "vendored foliate-js must ship in the module bundle")
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `swift test --filter LocatorTests`
Expected: FAIL — `cannot find 'Locator'`.

- [ ] **Step 5: Implement Locator.swift**

```swift
// Sources/IqraReader/Locator.swift
import Foundation

/// Composite reading position (spec "Locator model"): the CFI is the precise coordinate,
/// progression fractions are display/fallback only — never anchors.
public struct Locator: Codable, Equatable, Sendable {
    public var spineIndex: Int
    public var spineHref: String?
    public var cfi: String?
    public var progressionInChapter: Double?
    public var totalProgression: Double
    public var tocLabel: String?

    public init(spineIndex: Int, spineHref: String? = nil, cfi: String? = nil,
                progressionInChapter: Double? = nil, totalProgression: Double,
                tocLabel: String? = nil) {
        self.spineIndex = spineIndex; self.spineHref = spineHref; self.cfi = cfi
        self.progressionInChapter = progressionInChapter
        self.totalProgression = totalProgression; self.tocLabel = tocLabel
    }

    public func jsonData() throws -> Data { try JSONEncoder().encode(self) }
    public static func from(jsonData: Data) throws -> Locator {
        try JSONDecoder().decode(Locator.self, from: jsonData)
    }
}

public struct ReaderTheme: Codable, Equatable, Sendable {
    public var background: String
    public var foreground: String
    public init(background: String, foreground: String) {
        self.background = background; self.foreground = foreground
    }
    public static let light = ReaderTheme(background: "#ffffff", foreground: "#1a1a1a")
    public static let sepia = ReaderTheme(background: "#f4ecd8", foreground: "#5b4636")
    public static let dark  = ReaderTheme(background: "#121212", foreground: "#d6d6d6")
}

public struct ReaderSettings: Codable, Equatable, Sendable {
    public var fontSizePercent: Int
    public var fontFamily: String?
    public var lineHeight: Double
    public var justify: Bool
    public var theme: ReaderTheme
    public var flow: Flow
    public enum Flow: String, Codable, Sendable { case paginated, scrolled }

    public init(fontSizePercent: Int = 100, fontFamily: String? = nil, lineHeight: Double = 1.4,
                justify: Bool = false, theme: ReaderTheme = .light, flow: Flow = .paginated) {
        self.fontSizePercent = fontSizePercent; self.fontFamily = fontFamily
        self.lineHeight = lineHeight; self.justify = justify; self.theme = theme; self.flow = flow
    }
    public static let `default` = ReaderSettings()
}
```

- [ ] **Step 6: Run tests to verify pass**

Run: `swift test --filter LocatorTests`
Expected: PASS (3 tests — including the bundled-resource check; if `Bundle.module.url(forResource:"Vendor/foliate-js/view"...)` returns nil due to `.copy` directory semantics, the correct lookup is `Bundle.module.url(forResource: "view", withExtension: "js", subdirectory: "Vendor/foliate-js")` — adjust the test to whichever the SPM resource layout actually produces and note it).

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/IqraReader Tests/IqraReaderTests
git commit -m "feat: IqraReader target with vendored foliate-js (pinned 78914ae) and Locator model"
```

---

### Task 6: BookResourceSchemeHandler

**Files:**
- Create: `Sources/IqraReader/BookResourceSchemeHandler.swift`
- Test: `Tests/IqraReaderTests/SchemeHandlerTests.swift`

**Interfaces:**
- Consumes: `Bundle.module` (vendored JS; reader assets from Task 7), a book file URL.
- Produces:

```swift
public enum BookScheme {
    public static let scheme = "iqra-book"
    public static func pageURL(bookID: UUID) -> URL   // iqra-book://<uuid-lowercased>/index.html
}
/// Resolves scheme URLs to responses. Pure logic, unit-testable without WebKit.
public struct BookResourceResolver: Sendable {
    public init(bookID: UUID, bookFileURL: URL, bundle: Bundle = .module)
    public struct Response { public let data: Data; public let mimeType: String }
    public func response(for url: URL) -> Response?   // nil = 404
    public static let contentSecurityPolicy: String
}
public final class BookResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    public init(resolver: BookResourceResolver)
}
```

URL layout (ONE origin per book — module scripts and fetch must be same-origin; in-scheme CORS is broken in WKURLSchemeHandler, WebKit bug 201180):

- `iqra-book://<bookUUID>/index.html` → `Resources/reader.html` (Task 7; until then 404 is fine — tests use vendor + book paths)
- `iqra-book://<bookUUID>/bridge.js` → `Resources/bridge.js`
- `iqra-book://<bookUUID>/vendor/foliate-js/...` → vendored files
- `iqra-book://<bookUUID>/book.epub` → the book file bytes

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IqraReaderTests/SchemeHandlerTests.swift
import XCTest
@testable import IqraReader

final class SchemeHandlerTests: XCTestCase {
    var bookURL: URL!
    var bookID: UUID!
    var resolver: BookResourceResolver!

    override func setUpWithError() throws {
        bookID = UUID()
        bookURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".epub")
        try Data("fake epub bytes".utf8).write(to: bookURL)
        resolver = BookResourceResolver(bookID: bookID, bookFileURL: bookURL)
    }

    func url(_ path: String) -> URL {
        URL(string: "iqra-book://\(bookID.uuidString.lowercased())\(path)")!
    }

    func testServesBookBytes() throws {
        let r = try XCTUnwrap(resolver.response(for: url("/book.epub")))
        XCTAssertEqual(r.data, Data("fake epub bytes".utf8))
        XCTAssertEqual(r.mimeType, "application/epub+zip")
    }

    func testServesVendoredJSWithCorrectMIME() throws {
        let r = try XCTUnwrap(resolver.response(for: url("/vendor/foliate-js/view.js")))
        XCTAssertEqual(r.mimeType, "text/javascript")
        XCTAssertTrue(String(decoding: r.data, as: UTF8.self).contains("foliate-view"))
    }

    func testRejectsWrongHost() {
        let other = URL(string: "iqra-book://\(UUID().uuidString.lowercased())/book.epub")!
        XCTAssertNil(resolver.response(for: other))
    }

    func testRejectsPathTraversal() {
        XCTAssertNil(resolver.response(for: url("/vendor/foliate-js/../../secrets")))
        XCTAssertNil(resolver.response(for: url("/../etc/passwd")))
    }

    func testUnknownPathIs404() {
        XCTAssertNil(resolver.response(for: url("/nope.js")))
    }

    func testCSPForbidsRemoteScript() {
        let csp = BookResourceResolver.contentSecurityPolicy
        XCTAssertTrue(csp.contains("script-src 'self'"))
        XCTAssertTrue(csp.contains("form-action 'none'"))
        XCTAssertFalse(csp.contains("unsafe-eval"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SchemeHandlerTests`
Expected: FAIL — `cannot find 'BookResourceResolver'`.

- [ ] **Step 3: Implement**

```swift
// Sources/IqraReader/BookResourceSchemeHandler.swift
import Foundation
import WebKit

public enum BookScheme {
    public static let scheme = "iqra-book"
    public static func pageURL(bookID: UUID) -> URL {
        URL(string: "\(scheme)://\(bookID.uuidString.lowercased())/index.html")!
    }
}

/// Maps iqra-book:// URLs to data. One instance serves exactly one book (unique host per
/// book = per-book origin isolation, spec "Security"). Pure and unit-testable — the
/// WKURLSchemeHandler below is a thin adapter.
public struct BookResourceResolver: Sendable {
    public struct Response {
        public let data: Data
        public let mimeType: String
    }

    /// Reference CSP from upstream foliate-js reader.html, tightened: no remote anything;
    /// blob:/data: allowances are what the in-page zip → blob-URL pipeline needs.
    public static let contentSecurityPolicy = [
        "default-src 'self' blob:",
        "script-src 'self'",
        "style-src 'self' blob: 'unsafe-inline'",
        "img-src 'self' blob: data:",
        "font-src 'self' blob: data:",
        "connect-src 'self' blob: data:",
        "frame-src blob: data:",
        "object-src blob: data:",
        "form-action 'none'",
    ].joined(separator: "; ")

    let bookID: UUID
    let bookFileURL: URL
    let bundle: Bundle

    public init(bookID: UUID, bookFileURL: URL, bundle: Bundle = .module) {
        self.bookID = bookID; self.bookFileURL = bookFileURL; self.bundle = bundle
    }

    public func response(for url: URL) -> Response? {
        guard url.scheme == BookScheme.scheme,
              url.host()?.lowercased() == bookID.uuidString.lowercased() else { return nil }
        // Normalize and forbid traversal: no component may be "..".
        let components = url.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        let path = components.joined(separator: "/")

        switch path {
        case "book.epub":
            guard let data = try? Data(contentsOf: bookFileURL) else { return nil }
            return Response(data: data, mimeType: "application/epub+zip")
        case "index.html":
            return bundled("Resources/reader.html", mime: "text/html")
        case "bridge.js":
            return bundled("Resources/bridge.js", mime: "text/javascript")
        default:
            guard path.hasPrefix("vendor/foliate-js/") else { return nil }
            let mime = path.hasSuffix(".js") ? "text/javascript" : "application/octet-stream"
            return bundled("Vendor/foliate-js/" + path.dropFirst("vendor/foliate-js/".count),
                           mime: mime)
        }
    }

    private func bundled(_ relativePath: String, mime: String) -> Response? {
        // .copy resources preserve directory structure under the bundle root.
        let fileURL = bundle.resourceURL?.appendingPathComponent(relativePath)
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return Response(data: data, mimeType: mime)
    }
}

public final class BookResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    let resolver: BookResourceResolver
    public init(resolver: BookResourceResolver) { self.resolver = resolver }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let response = resolver.response(for: url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = [
            "Content-Type": response.mimeType,
            "Content-Length": String(response.data.count),
            "Content-Security-Policy": BookResourceResolver.contentSecurityPolicy,
        ]
        let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: headers)!
        task.didReceive(http)
        task.didReceive(response.data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Whole responses are delivered synchronously above; nothing to cancel.
    }
}
```

Note for the implementer: `url.host()` is the iOS16+/macOS13+ API; the floors (17/14) cover it. If `bundle.resourceURL` nesting differs from `Resources/...` (SPM sometimes flattens `.copy` of a directory to its basename), adjust `bundled(_:)`'s prefixes to the actual layout revealed by `testServesVendoredJSWithCorrectMIME` — the test defines the contract, the lookup adapts.

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter SchemeHandlerTests`
Expected: PASS (6 tests; `index.html`/`bridge.js` cases stay untested until Task 7 adds the files).

- [ ] **Step 5: Commit**

```bash
git add Sources/IqraReader Tests/IqraReaderTests
git commit -m "feat: per-book custom-scheme resource handler with strict CSP"
```

---

### Task 7: ReadingStateStore + open-book queries

**Files:**
- Create: `Sources/IqraLibrary/Database/ReadingStateStore.swift`
- Modify: `Sources/IqraLibrary/Database/LibraryStore.swift` (add `openableFormat`, `markOpened`)
- Test: `Tests/IqraLibraryTests/ReadingStateStoreTests.swift`

**Interfaces:**
- Consumes: `DatabaseManager`, existing `reading_state` table (per (book, format): `currentLocator` TEXT, `candidates` TEXT default '[]', `highWaterMark` DOUBLE, `applySeq`, unique(bookId, formatId)), `FormatRecord`.
- Produces:

```swift
public final class ReadingStateStore: @unchecked Sendable {
    public init(dbm: DatabaseManager)
    public func locatorJSON(bookID: UUID, formatID: UUID) throws -> Data?
    public func highWaterMark(bookID: UUID, formatID: UUID) throws -> Double
    /// Upserts the current locator; highWaterMark only ever grows (max-merge, spec).
    /// Returns the resulting high-water mark.
    @discardableResult
    public func saveLocator(json: Data, totalProgression: Double,
                            bookID: UUID, formatID: UUID) throws -> Double
}
// LibraryStore additions:
public func openableFormat(bookID: UUID) throws -> FormatRecord?  // first locally-present epub
public func markOpened(bookID: UUID) throws                        // lastOpenedAt = now, applySeq bump
```

The store persists the locator as an opaque JSON blob — IqraLibrary never learns the `Locator` type (package boundary: IqraLibrary never imports reader code; `Locator` lives in IqraReader).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IqraLibraryTests/ReadingStateStoreTests.swift
import XCTest
import IqraCore
import GRDB
@testable import IqraLibrary

final class ReadingStateStoreTests: XCTestCase {
    var dbm: DatabaseManager!
    var store: LibraryStore!
    var reading: ReadingStateStore!
    var bookID: UUID!
    var formatID: UUID!

    override func setUpWithError() throws {
        dbm = try DatabaseManager.inMemory()
        store = LibraryStore(dbm: dbm)
        reading = ReadingStateStore(dbm: dbm)
        bookID = UUID(); formatID = UUID()
        let meta = ExtractedMetadata(title: "T", titleSort: "T", language: "en", publisher: nil,
                                     bookDescription: nil, contributors: [], identifiers: [])
        try store.insertBook(metadata: meta, formatType: .epub, originalFileName: "t.epub",
                             byteSize: 1, contentHash: "h", bookID: bookID, formatID: formatID)
    }

    func testSaveAndReadLocatorRoundTrip() throws {
        let json = Data(#"{"spineIndex":3,"totalProgression":0.25}"#.utf8)
        try reading.saveLocator(json: json, totalProgression: 0.25, bookID: bookID, formatID: formatID)
        XCTAssertEqual(try reading.locatorJSON(bookID: bookID, formatID: formatID), json)
        XCTAssertNil(try reading.locatorJSON(bookID: UUID(), formatID: UUID()))
    }

    func testHighWaterMarkOnlyGrows() throws {
        let j = Data("{}".utf8)
        XCTAssertEqual(try reading.saveLocator(json: j, totalProgression: 0.5,
                                               bookID: bookID, formatID: formatID), 0.5)
        // going BACK in the book must not lower the mark
        XCTAssertEqual(try reading.saveLocator(json: j, totalProgression: 0.2,
                                               bookID: bookID, formatID: formatID), 0.5)
        XCTAssertEqual(try reading.highWaterMark(bookID: bookID, formatID: formatID), 0.5)
        // but the CURRENT locator does move back
        let back = Data(#"{"totalProgression":0.2}"#.utf8)
        try reading.saveLocator(json: back, totalProgression: 0.2, bookID: bookID, formatID: formatID)
        XCTAssertEqual(try reading.locatorJSON(bookID: bookID, formatID: formatID), back)
    }

    func testSaveStampsApplySequence() throws {
        try reading.saveLocator(json: Data("{}".utf8), totalProgression: 0.1,
                                bookID: bookID, formatID: formatID)
        let seq1 = try dbm.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT applySeq FROM reading_state")!
        }
        try reading.saveLocator(json: Data("{}".utf8), totalProgression: 0.2,
                                bookID: bookID, formatID: formatID)
        let seq2 = try dbm.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT applySeq FROM reading_state")!
        }
        XCTAssertGreaterThan(seq2, seq1)
    }

    func testOpenableFormatAndMarkOpened() throws {
        let format = try XCTUnwrap(try store.openableFormat(bookID: bookID))
        XCTAssertEqual(format.id, formatID.uuidString)
        // a missing binary is not openable
        try dbm.writer.write { db in
            try db.execute(sql: "UPDATE format_local SET present = 0, missing = 1 WHERE formatId = ?",
                           arguments: [formatID.uuidString])
        }
        XCTAssertNil(try store.openableFormat(bookID: bookID))

        try store.markOpened(bookID: bookID)
        let opened = try dbm.writer.read { db in
            try Date.fetchOne(db, sql: "SELECT lastOpenedAt FROM book WHERE id = ?",
                              arguments: [bookID.uuidString])
        }
        XCTAssertNotNil(opened)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReadingStateStoreTests`
Expected: FAIL — `cannot find 'ReadingStateStore'`.

- [ ] **Step 3: Implement**

```swift
// Sources/IqraLibrary/Database/ReadingStateStore.swift
import Foundation
import GRDB

/// Persistence for reading positions (spec "Identity, versioning & reading-state model").
/// The locator is an opaque JSON blob to this layer — IqraLibrary never imports reader
/// types. `highWaterMark` is merged by max and never regresses; the current locator moves
/// freely (a reader re-reading from 5% must not be dragged forward).
public final class ReadingStateStore: @unchecked Sendable {
    let dbm: DatabaseManager
    public init(dbm: DatabaseManager) { self.dbm = dbm }

    public func locatorJSON(bookID: UUID, formatID: UUID) throws -> Data? {
        try dbm.writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT currentLocator FROM reading_state WHERE bookId = ? AND formatId = ?
                """, arguments: [bookID.uuidString, formatID.uuidString])
                .map { Data($0.utf8) }
        }
    }

    public func highWaterMark(bookID: UUID, formatID: UUID) throws -> Double {
        try dbm.writer.read { db in
            try Double.fetchOne(db, sql: """
                SELECT highWaterMark FROM reading_state WHERE bookId = ? AND formatId = ?
                """, arguments: [bookID.uuidString, formatID.uuidString]) ?? 0
        }
    }

    @discardableResult
    public func saveLocator(json: Data, totalProgression: Double,
                            bookID: UUID, formatID: UUID) throws -> Double {
        try dbm.writer.write { db in
            let seq = try dbm.nextApplySequence(db)
            try db.execute(sql: """
                INSERT INTO reading_state (id, bookId, formatId, currentLocator, candidates,
                                           highWaterMark, applySeq)
                VALUES (?, ?, ?, ?, '[]', ?, ?)
                ON CONFLICT(bookId, formatId) DO UPDATE SET
                    currentLocator = excluded.currentLocator,
                    highWaterMark = MAX(reading_state.highWaterMark, excluded.highWaterMark),
                    applySeq = excluded.applySeq
                """, arguments: [UUID().uuidString, bookID.uuidString, formatID.uuidString,
                                 String(decoding: json, as: UTF8.self), totalProgression, seq])
            return try Double.fetchOne(db, sql: """
                SELECT highWaterMark FROM reading_state WHERE bookId = ? AND formatId = ?
                """, arguments: [bookID.uuidString, formatID.uuidString]) ?? totalProgression
        }
    }
}
```

Append to `Sources/IqraLibrary/Database/LibraryStore.swift` (in the queries extension):

```swift
    /// The format the reader opens for this book: the first locally-present, non-deleted
    /// EPUB. (Other format types get navigators in M4/M5.)
    public func openableFormat(bookID: UUID) throws -> FormatRecord? {
        try dbm.writer.read { db in
            try FormatRecord.fetchOne(db, sql: """
                SELECT f.* FROM format f
                JOIN format_local fl ON fl.formatId = f.id
                WHERE f.bookId = ? AND f.deleted = 0 AND f.formatType = 'epub' AND fl.present = 1
                ORDER BY f.addedAt ASC LIMIT 1
                """, arguments: [bookID.uuidString])
        }
    }

    public func markOpened(bookID: UUID) throws {
        try dbm.writer.write { db in
            let seq = try dbm.nextApplySequence(db)
            try db.execute(sql: "UPDATE book SET lastOpenedAt = ?, applySeq = ? WHERE id = ?",
                           arguments: [Date(), seq, bookID.uuidString])
        }
    }
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter ReadingStateStoreTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Full suite + commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/IqraLibrary Tests/IqraLibraryTests
git commit -m "feat: reading-state persistence with max-merged high-water mark and open-book queries"
```

---

### Task 8: reader.html + bridge.js + EPUBNavigator (WKWebView integration)

**Files:**
- Create: `Sources/IqraReader/Resources/reader.html`, `Sources/IqraReader/Resources/bridge.js`
- Create: `Sources/IqraReader/EPUBNavigator.swift`, `Sources/IqraReader/NavigatorProtocols.swift`
- Modify: `Package.swift` (IqraReaderTests gains ZIPFoundation for the fixture builder)
- Test: `Tests/IqraReaderTests/EPUBNavigatorTests.swift` (+ a self-contained EPUB fixture helper)

**Interfaces:**
- Consumes: `BookResourceResolver`/`BookResourceSchemeHandler`/`BookScheme` (Task 6), `Locator`/`ReaderSettings` (Task 5).
- Produces:

```swift
public struct TOCItem: Codable, Equatable, Sendable {
    public let label: String
    public let href: String?
    public let subitems: [TOCItem]?
}
@MainActor public protocol NavigatorDelegate: AnyObject {
    func navigatorDidLoad(title: String?, toc: [TOCItem])
    func navigator(didRelocate locator: Locator)
    func navigator(didFail message: String)
}
@MainActor public final class EPUBNavigator: NSObject {
    public let webView: WKWebView
    public weak var delegate: NavigatorDelegate?
    public private(set) var lastLocator: Locator?
    public init(bookID: UUID, bookFileURL: URL, initialLocator: Locator?, settings: ReaderSettings)
    public func start()                       // compiles the content blocker, then loads the page
    public func goTo(cfi: String)
    public func goTo(fraction: Double)
    public func next(); public func prev()
    public func apply(settings: ReaderSettings)
}
```

**Bridge protocol** (single message-handler channel `iqra`; every payload is `{type, ...}`):
- JS→Swift: `{type:"ready"}` (module loaded) · `{type:"loaded", title, toc:[{label,href,subitems}]}` · `{type:"relocate", spineIndex, spineHref, cfi, progressionInChapter, totalProgression, tocLabel}` · `{type:"error", message}`
- Swift→JS (evaluateJavaScript): `iqra.start(configJSON)` where config = `{settings, lastCFI}` · `iqra.goTo(target)` (CFI string or `{fraction}`) · `iqra.next()` / `iqra.prev()` · `iqra.setAppearance(settingsJSON)`

- [ ] **Step 1: Write reader.html**

```html
<!-- Sources/IqraReader/Resources/reader.html -->
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <!-- Belt and braces: the scheme handler also sends this CSP as a response header. -->
  <meta http-equiv="Content-Security-Policy"
        content="default-src 'self' blob:; script-src 'self'; style-src 'self' blob: 'unsafe-inline'; img-src 'self' blob: data:; font-src 'self' blob: data:; connect-src 'self' blob: data:; frame-src blob: data:; object-src blob: data:; form-action 'none'">
  <style>
    html, body { margin: 0; padding: 0; height: 100%; overflow: hidden; }
    foliate-view { display: block; width: 100%; height: 100%; }
  </style>
</head>
<body>
  <script type="module" src="./bridge.js"></script>
</body>
</html>
```

- [ ] **Step 2: Write bridge.js**

```js
// Sources/IqraReader/Resources/bridge.js
// The ONLY channel between book content and the app (spec: Thorium's preload pattern).
// Runs as a module in the reader page; talks to Swift via webkit.messageHandlers.iqra.
import './vendor/foliate-js/view.js'
import { EPUB } from './vendor/foliate-js/epub.js'
import { configure, ZipReader, BlobReader, TextWriter, BlobWriter } from './vendor/foliate-js/vendor/zip.js'

const post = payload => window.webkit?.messageHandlers?.iqra?.postMessage(payload)
window.addEventListener('error', e => post({ type: 'error', message: String(e.message) }))
window.addEventListener('unhandledrejection', e => post({ type: 'error', message: String(e.reason) }))

// Pure-JS SHA-1 (custom schemes are not secure contexts, so crypto.subtle is
// unavailable). Needed only for IDPF font deobfuscation. Input/output: ArrayBuffer.
const sha1 = async buffer => {
    const rotl = (n, b) => (n << b) | (n >>> (32 - b))
    const bytes = new Uint8Array(buffer)
    const ml = bytes.length
    const withPadding = new Uint8Array(((ml + 8) >> 6 << 6) + 64)
    withPadding.set(bytes)
    withPadding[ml] = 0x80
    const dv = new DataView(withPadding.buffer)
    dv.setUint32(withPadding.length - 4, ml << 3)
    dv.setUint32(withPadding.length - 8, ml / 0x20000000 | 0)
    let [h0, h1, h2, h3, h4] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    const w = new Uint32Array(80)
    for (let i = 0; i < withPadding.length; i += 64) {
        for (let j = 0; j < 16; j++) w[j] = dv.getUint32(i + j * 4)
        for (let j = 16; j < 80; j++) w[j] = rotl(w[j-3] ^ w[j-8] ^ w[j-14] ^ w[j-16], 1)
        let [a, b, c, d, e] = [h0, h1, h2, h3, h4]
        for (let j = 0; j < 80; j++) {
            const [f, k] = j < 20 ? [(b & c) | (~b & d), 0x5A827999]
                : j < 40 ? [b ^ c ^ d, 0x6ED9EBA1]
                : j < 60 ? [(b & c) | (b & d) | (c & d), 0x8F1BBCDC]
                : [b ^ c ^ d, 0xCA62C1D6]
            const t = (rotl(a, 5) + f + e + k + w[j]) | 0
            e = d; d = c; c = rotl(b, 30); b = a; a = t
        }
        h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0; h4 = (h4 + e) | 0
    }
    const out = new DataView(new ArrayBuffer(20))
    ;[h0, h1, h2, h3, h4].forEach((h, i) => out.setUint32(i * 4, h >>> 0))
    return out.buffer
}

const view = document.createElement('foliate-view')
document.body.append(view)
let sectionHrefs = []

view.addEventListener('relocate', e => {
    const { cfi, fraction, tocItem, section } = e.detail
    const spineIndex = section?.current ?? 0
    post({
        type: 'relocate',
        spineIndex,
        spineHref: sectionHrefs[spineIndex] ?? null,
        cfi: cfi ?? null,
        progressionInChapter: null, // section-level fraction is renderer-internal; display-only anyway
        totalProgression: fraction ?? 0,
        tocLabel: tocItem?.label ?? null,
    })
})

const flattenTOC = items => (items ?? []).map(({ label, href, subitems }) =>
    ({ label: label ?? '', href: href ?? null, subitems: subitems?.length ? flattenTOC(subitems) : null }))

const getCSS = s => [`
    @namespace epub "http://www.idpf.org/2007/ops";
    html { color-scheme: light dark; }
`, `
    html, body { color: ${s.theme.foreground} !important;
                 background: ${s.theme.background} !important; }
    html { font-size: ${s.fontSizePercent}% !important; }
    html, body, p, li, blockquote, dd {
        line-height: ${s.lineHeight} !important;
        text-align: ${s.justify ? 'justify' : 'start'};
    }
    ${s.fontFamily ? `html, body, p, li, blockquote, dd { font-family: ${s.fontFamily} !important; }` : ''}
`]

const applySettings = s => {
    view.renderer.setAttribute('flow', s.flow === 'scrolled' ? 'scrolled' : 'paginated')
    view.renderer.setStyles?.(getCSS(s))
}

window.iqra = {
    async start(config) {
        try {
            const res = await fetch('/book.epub')
            if (!res.ok) throw new Error(`book fetch failed: ${res.status}`)
            const blob = await res.blob()
            configure({ useWebWorkers: false })
            const reader = new ZipReader(new BlobReader(blob))
            const entries = await reader.getEntries()
            const map = new Map(entries.map(e => [e.filename, e]))
            const load = f => (name, ...args) =>
                map.has(name) ? map.get(name).getData(new f(...args)) : null
            const book = await new EPUB({
                loadText: load(TextWriter),
                loadBlob: name => map.has(name) ? map.get(name).getData(new BlobWriter()) : null,
                getSize: name => map.get(name)?.uncompressedSize ?? 0,
                sha1,
            }).init()
            await view.open(book)
            sectionHrefs = (book.sections ?? []).map(s => s.id ?? null)
            applySettings(config.settings)
            post({
                type: 'loaded',
                title: typeof book.metadata?.title === 'string'
                    ? book.metadata.title
                    : Object.values(book.metadata?.title ?? {})[0] ?? null,
                toc: flattenTOC(book.toc),
            })
            await view.init({ lastLocation: config.lastCFI ?? undefined, showTextStart: true })
        } catch (err) {
            post({ type: 'error', message: String(err?.message ?? err) })
        }
    },
    goTo: target => view.goTo(target),
    next: () => view.next(),
    prev: () => view.prev(),
    setAppearance: s => applySettings(s),
}

post({ type: 'ready' })
```

- [ ] **Step 3: Write NavigatorProtocols.swift and EPUBNavigator.swift**

```swift
// Sources/IqraReader/NavigatorProtocols.swift
import Foundation

/// Base navigator surface (spec: protocol composition — capability protocols like
/// TextSelectable/RangeAnnotatable arrive with their features in M3/M4).
@MainActor
public protocol NavigatorDelegate: AnyObject {
    func navigatorDidLoad(title: String?, toc: [TOCItem])
    func navigator(didRelocate locator: Locator)
    func navigator(didFail message: String)
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

```swift
// Sources/IqraReader/EPUBNavigator.swift
import Foundation
import WebKit

/// Owns one WKWebView rendering one EPUB via foliate-js. All communication with page JS
/// goes through the single `iqra` message channel; all durable state is the caller's
/// responsibility (persist on every relocate — the DB, not the web view, is the source
/// of truth; spec "Process-kill recovery contract").
@MainActor
public final class EPUBNavigator: NSObject {
    public let webView: WKWebView
    public weak var delegate: NavigatorDelegate?
    public private(set) var lastLocator: Locator?

    private let bookID: UUID
    private var settings: ReaderSettings
    private let initialLocator: Locator?

    public init(bookID: UUID, bookFileURL: URL, initialLocator: Locator?,
                settings: ReaderSettings) {
        self.bookID = bookID
        self.settings = settings
        self.initialLocator = initialLocator

        let resolver = BookResourceResolver(bookID: bookID, bookFileURL: bookFileURL)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BookResourceSchemeHandler(resolver: resolver),
                                   forURLScheme: BookScheme.scheme)
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(MessageProxy(self), name: "iqra")
        webView.navigationDelegate = self
        #if os(iOS)
        webView.scrollView.bounces = false
        webView.isOpaque = false
        #endif
    }

    /// Compiles the network-blocking rule list, then loads the reader page.
    public func start() {
        // Block every load except our custom scheme (spec: WKContentRuleList blocks all
        // remote loads; the CSP is the second layer).
        let rules = """
        [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
         {"trigger": {"url-filter": "^iqra-book://.*"}, "action": {"type": "ignore-previous-rules"}},
         {"trigger": {"url-filter": "^blob:.*"}, "action": {"type": "ignore-previous-rules"}},
         {"trigger": {"url-filter": "^data:.*"}, "action": {"type": "ignore-previous-rules"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "iqra-book-blocklist", encodedContentRuleList: rules) { [weak self] list, error in
            Task { @MainActor in
                guard let self else { return }
                if let list {
                    self.webView.configuration.userContentController.add(list)
                } else if let error {
                    // Rule-list failure must not brick reading — CSP still blocks remote
                    // loads. Surface it so it is never silent.
                    self.delegate?.navigator(didFail: "content blocker unavailable: \(error)")
                }
                self.webView.load(URLRequest(url: BookScheme.pageURL(bookID: self.bookID)))
            }
        }
    }

    public func goTo(cfi: String) { call("iqra.goTo(\(jsString(cfi)))") }
    public func goTo(fraction: Double) { call("iqra.goTo({fraction: \(fraction)})") }
    public func next() { call("iqra.next()") }
    public func prev() { call("iqra.prev()") }

    public func apply(settings: ReaderSettings) {
        self.settings = settings
        if let json = try? String(decoding: JSONEncoder().encode(settings), as: UTF8.self) {
            call("iqra.setAppearance(\(json))")
        }
    }

    // MARK: - JS plumbing

    private func call(_ js: String) {
        webView.evaluateJavaScript(js) { _, error in
            if error != nil { /* page not ready yet; commands re-issue on ready/reload */ }
        }
    }

    private func jsString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode([s])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast()) // "…" JSON-escaped
    }

    fileprivate func handle(message body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            var config: [String: Any] = [:]
            if let data = try? JSONEncoder().encode(settings),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                config["settings"] = obj
            }
            if let cfi = initialLocator?.cfi ?? lastLocator?.cfi {
                config["lastCFI"] = cfi
            }
            if let data = try? JSONSerialization.data(withJSONObject: config) {
                call("iqra.start(\(String(decoding: data, as: UTF8.self)))")
            }
        case "loaded":
            let title = dict["title"] as? String
            let toc = (try? JSONSerialization.data(withJSONObject: dict["toc"] ?? []))
                .flatMap { try? JSONDecoder().decode([TOCItem].self, from: $0) } ?? []
            delegate?.navigatorDidLoad(title: title, toc: toc)
        case "relocate":
            let locator = Locator(
                spineIndex: dict["spineIndex"] as? Int ?? 0,
                spineHref: dict["spineHref"] as? String,
                cfi: dict["cfi"] as? String,
                progressionInChapter: dict["progressionInChapter"] as? Double,
                totalProgression: dict["totalProgression"] as? Double ?? 0,
                tocLabel: dict["tocLabel"] as? String)
            lastLocator = locator
            delegate?.navigator(didRelocate: locator)
        case "error":
            delegate?.navigator(didFail: dict["message"] as? String ?? "unknown reader error")
        default:
            break
        }
    }
}

extension EPUBNavigator: WKNavigationDelegate {
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Spec recovery contract: rebuild from the last committed state. The page reloads,
        // posts "ready", and the ready handler re-sends settings + lastLocator's CFI.
        webView.load(URLRequest(url: BookScheme.pageURL(bookID: bookID)))
    }
}

/// Breaks the WKUserContentController → handler retain cycle (it retains its handlers).
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var navigator: EPUBNavigator?
    init(_ navigator: EPUBNavigator) { self.navigator = navigator }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { navigator?.handle(message: message.body) }
    }
}
```

- [ ] **Step 4: Add ZIPFoundation to IqraReaderTests + write the integration test**

In `Package.swift`: `.testTarget(name: "IqraReaderTests", dependencies: ["IqraReader", .product(name: "ZIPFoundation", package: "ZIPFoundation")]),`

```swift
// Tests/IqraReaderTests/EPUBNavigatorTests.swift
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
}
```

- [ ] **Step 5: Run the integration tests**

Run: `swift test --filter EPUBNavigatorTests`
Expected: PASS. WKWebView in an SPM test host on macOS is expected to work (the XCTest waiter pumps the run loop). If BOTH tests fail with WebKit process errors (not assertion failures), apply the global-constraints escape hatch: wrap in `try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, ...)` is NOT the fix — instead report DONE_WITH_CONCERNS describing the exact failure; the controller decides between an app-hosted test target and accepting smoke-test coverage. Do not silently skip.

- [ ] **Step 6: Full suite + commit**

Run: `swift test`
Expected: PASS (all targets).

```bash
git add Package.swift Sources/IqraReader Tests/IqraReaderTests
git commit -m "feat: foliate-js bridge and EPUBNavigator with locator round-trip"
```

---

### Task 9: Dynamic appearance — settings changes reach the rendered page

**Files:**
- Test: `Tests/IqraReaderTests/EPUBNavigatorAppearanceTests.swift`
- Modify: `Sources/IqraReader/Resources/bridge.js` / `Sources/IqraReader/EPUBNavigator.swift` ONLY if the tests reveal gaps (the Task 8 code is believed complete; this task is the proof)

**Interfaces:**
- Consumes: `EPUBNavigator.apply(settings:)`, bridge `iqra.setAppearance`.
- Produces: verified behavior; no new API.

- [ ] **Step 1: Write the failing/verifying test**

```swift
// Tests/IqraReaderTests/EPUBNavigatorAppearanceTests.swift
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
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter EPUBNavigatorAppearanceTests`
Expected: PASS if Task 8's bridge is complete. If it FAILS, the failure is a real gap — fix `bridge.js`'s `applySettings`/`getCSS` (most likely suspects: `setStyles` array form, `!important` precedence against publisher CSS) and re-run until green. Either way the test stays.

- [ ] **Step 3: Full suite + commit**

Run: `swift test`
Expected: PASS.

```bash
git add Sources/IqraReader Tests/IqraReaderTests
git commit -m "test: dynamic theme and flow changes verified against rendered content"
```

---

### Task 10: Reader UI — screen, view model, settings persistence, library wiring

**Files:**
- Create: `App/Sources/ReaderScreen.swift`, `App/Sources/ReaderViewModel.swift`, `App/Sources/ReaderSettingsStore.swift`
- Modify: `App/Sources/LibraryView.swift` (tap to open), `App/Sources/LibraryViewModel.swift` (expose stores/paths for the reader)
- Test: none (app target has no test gate — all logic above is package-tested; Task 11 verifies builds; the human smoke test covers interaction)

**Interfaces:**
- Consumes: `EPUBNavigator`, `NavigatorDelegate`, `Locator`, `ReaderSettings` (IqraReader); `ReadingStateStore`, `LibraryStore.openableFormat/markOpened`, `LibraryPaths.formatFile` (IqraLibrary).
- Produces: tapping a library book opens the reader; position persists on every relocate and restores on reopen; appearance popover (theme/font size/line height/justify/flow) applies live and persists globally.

- [ ] **Step 1: Write ReaderSettingsStore.swift**

```swift
// App/Sources/ReaderSettingsStore.swift
import Foundation
import IqraReader

/// Global appearance settings, persisted as JSON in UserDefaults. Per-book overrides are
/// a later milestone; the schema-level home for synced settings arrives with M7.
enum ReaderSettingsStore {
    private static let key = "reader.settings.v1"

    static func load() -> ReaderSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(ReaderSettings.self, from: data)
        else { return .default }
        return settings
    }

    static func save(_ settings: ReaderSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
```

- [ ] **Step 2: Write ReaderViewModel.swift**

```swift
// App/Sources/ReaderViewModel.swift
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
    var settings: ReaderSettings {
        didSet {
            navigator.apply(settings: settings)
            ReaderSettingsStore.save(settings)
        }
    }

    private let bookID: UUID
    private let formatID: UUID
    private let readingState: ReadingStateStore

    init?(bookID: UUID, store: LibraryStore, readingState: ReadingStateStore, paths: LibraryPaths) {
        guard let format = try? store.openableFormat(bookID: bookID),
              let formatUUID = UUID(uuidString: format.id),
              let type = FormatType(rawValue: format.formatType) else { return nil }
        self.bookID = bookID
        self.formatID = formatUUID
        self.readingState = readingState
        self.settings = ReaderSettingsStore.load()

        let initial = (try? readingState.locatorJSON(bookID: bookID, formatID: formatUUID))
            .flatMap { try? Locator.from(jsonData: $0) }
        self.navigator = EPUBNavigator(
            bookID: bookID,
            bookFileURL: paths.formatFile(bookID: bookID, formatID: formatUUID, type: type),
            initialLocator: initial,
            settings: ReaderSettingsStore.load())
        navigator.delegate = self
        try? store.markOpened(bookID: bookID)
        navigator.start()
    }

    // MARK: NavigatorDelegate — every relocate commits to the DB before anything else
    // (spec: the DB, not the web view, is the source of truth).

    func navigatorDidLoad(title: String?, toc: [TOCItem]) {
        self.title = title
        self.toc = toc
    }

    func navigator(didRelocate locator: Locator) {
        progressPercent = Int((locator.totalProgression * 100).rounded())
        tocLabel = locator.tocLabel
        if let json = try? locator.jsonData() {
            try? readingState.saveLocator(json: json, totalProgression: locator.totalProgression,
                                          bookID: bookID, formatID: formatID)
        }
    }

    func navigator(didFail message: String) {
        readerError = message
    }
}
```

- [ ] **Step 3: Write ReaderScreen.swift**

```swift
// App/Sources/ReaderScreen.swift
import SwiftUI
import WebKit
import IqraReader

struct ReaderScreen: View {
    @State var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAppearance = false
    @State private var showTOC = false

    var body: some View {
        WebViewContainer(webView: model.navigator.webView)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(model.title ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup {
                    Text("\(model.progressPercent)%").font(.caption).foregroundStyle(.secondary)
                    Button("Previous", systemImage: "chevron.left") { model.navigator.prev() }
                    Button("Next", systemImage: "chevron.right") { model.navigator.next() }
                    Button("Contents", systemImage: "list.bullet") { showTOC = true }
                        .disabled(model.toc.isEmpty)
                    Button("Appearance", systemImage: "textformat.size") { showAppearance = true }
                }
            }
            .popover(isPresented: $showAppearance) { AppearanceControls(model: model) }
            .sheet(isPresented: $showTOC) { TOCList(items: model.toc, model: model) }
            .alert("Reader error", isPresented: .init(get: { model.readerError != nil },
                                                      set: { if !$0 { model.readerError = nil } })) {
                Button("OK") { model.readerError = nil }
            } message: { Text(model.readerError ?? "") }
            #if os(macOS)
            .onKeyPress(.leftArrow) { model.navigator.prev(); return .handled }
            .onKeyPress(.rightArrow) { model.navigator.next(); return .handled }
            #endif
    }
}

private struct AppearanceControls: View {
    @Bindable var model: ReaderViewModel

    var body: some View {
        Form {
            Picker("Theme", selection: $model.settings.theme) {
                Text("Light").tag(ReaderTheme.light)
                Text("Sepia").tag(ReaderTheme.sepia)
                Text("Dark").tag(ReaderTheme.dark)
            }
            Stepper("Text size: \(model.settings.fontSizePercent)%",
                    value: $model.settings.fontSizePercent, in: 70...200, step: 10)
            Stepper("Line height: \(model.settings.lineHeight, specifier: "%.1f")",
                    value: $model.settings.lineHeight, in: 1.0...2.2, step: 0.1)
            Toggle("Justify text", isOn: $model.settings.justify)
            Picker("Layout", selection: $model.settings.flow) {
                Text("Pages").tag(ReaderSettings.Flow.paginated)
                Text("Scroll").tag(ReaderSettings.Flow.scrolled)
            }
        }
        .padding()
        .frame(minWidth: 280)
    }
}

private struct TOCList: View {
    let items: [TOCItem]
    let model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List { TOCLevel(items: items, model: model, dismiss: dismiss) }
                .navigationTitle("Contents")
                .toolbar { ToolbarItem { Button("Done") { dismiss() } } }
        }
    }
}

private struct TOCLevel: View {
    let items: [TOCItem]
    let model: ReaderViewModel
    let dismiss: DismissAction

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Button(item.label) {
                if let href = item.href { model.navigator.goTo(cfi: href) } // goTo accepts hrefs too
                dismiss()
            }
            if let sub = item.subitems {
                TOCLevel(items: sub, model: model, dismiss: dismiss).padding(.leading, 16)
            }
        }
    }
}

private struct WebViewContainer {
    let webView: WKWebView
}

#if os(macOS)
extension WebViewContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension WebViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
```

Note: `goTo(cfi:)` deliberately passes hrefs too — foliate-js's `view.goTo` resolves CFI strings, hrefs, and fractions through one entry point (research §4); if the reviewer prefers, rename the navigator method to `goTo(target:)` — pick one and keep the bridge unchanged.

- [ ] **Step 4: Wire the library**

`App/Sources/LibraryViewModel.swift` — expose what the reader needs:

```swift
    // (inside LibraryViewModel)
    private(set) var readingState: ReadingStateStore?

    func readerModel(for bookID: UUID) -> ReaderViewModel? {
        guard let store, let readingState, let paths else { return nil }
        return ReaderViewModel(bookID: bookID, store: store,
                               readingState: readingState, paths: paths)
    }
```

and in `start()` after `store = LibraryStore(dbm: dbm)` add `readingState = ReadingStateStore(dbm: dbm)`.

`App/Sources/LibraryView.swift` — make the grid cell a navigation link (replace the cell `VStack` wrapper):

```swift
                    ForEach(model.books) { book in
                        NavigationLink(value: book.id) {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverView(url: model.coverURL(for: book.id))
                                Text(book.title).font(.callout).lineLimit(2)
                                Text(book.authors).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
```

and add after `.navigationTitle("Library")`:

```swift
            .navigationDestination(for: UUID.self) { bookID in
                if let reader = model.readerModel(for: bookID) {
                    ReaderScreen(model: reader)
                } else {
                    ContentUnavailableView("Can't open this book",
                        systemImage: "book.closed",
                        description: Text("No readable EPUB is available on this device."))
                }
            }
```

- [ ] **Step 5: Build both the packages and the app**

Run: `swift test && cd App && xcodegen generate && cd .. && xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build`
Expected: PASS + BUILD SUCCEEDED, zero warnings from app sources.

- [ ] **Step 6: Commit**

```bash
git add App
git commit -m "feat: reader screen with position persistence, TOC, and appearance controls"
```

---

### Task 11: Final assembly — iOS build, docs, smoke checklist

**Files:**
- Modify: `CLAUDE.md` (architecture bullet mentions IqraReader now exists), `docs/superpowers/plans/2026-07-12-m1-followups.md` (mark Early-M2 block done)
- Test: build verification only

- [ ] **Step 1: Verify the iOS build compiles (catches AppKit/UIKit divergence)**

Run: `xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'generic/platform=iOS Simulator' build`
Expected: BUILD SUCCEEDED. Fix any platform-conditional compilation issues this reveals (e.g. `onKeyPress` availability, `scrollView` access) — mechanical `#if os(...)` fixes are in scope; structural changes go back to the controller.

- [ ] **Step 2: Full suite one last time**

Run: `swift test`
Expected: PASS, zero warnings.

- [ ] **Step 3: Update docs**

In `CLAUDE.md`, update the architecture bullet `IqraReader (navigators: ...)` to reflect reality: EPUB navigator shipped (foliate-js vendored at pin 78914ae under `Sources/IqraReader/Vendor/`), PDFKit/comics navigators still pending (M4).

In `docs/superpowers/plans/2026-07-12-m1-followups.md`, mark the four "Early M2" items and the app-shell items this milestone absorbed as done (strike-through or "DONE (M2)" annotations), leaving the rest intact.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs
git commit -m "docs: M2 completion notes and follow-up ticket status"
```

- [ ] **Step 5: Manual smoke test (human — agents skip, controller reports it as owed)**

On macOS: import an EPUB → tap it → book renders paginated → arrow keys turn pages → progress % updates → quit mid-book → relaunch → reopen → position restored (same page ± one) → appearance popover: dark theme + larger text apply immediately → switch to Scroll layout → TOC sheet navigates to a chapter. On iOS Simulator: open the same book, swipe pages, rotate.

---

## Plan Self-Review Notes

- **Spec coverage (M2 scope):** foliate-js in WKWebView both platforms ✔ (Tasks 5–8); custom scheme + unique host per book + CSP + content blocker ✔ (Tasks 6, 8); Swift↔JS single-channel bridge ✔ (Task 8); composite Locator, CFI-anchored, fractions display-only ✔ (Tasks 5, 8); position persisted per (book, format) with max-merged high-water mark and apply-seq ✔ (Task 7); restore on reopen ✔ (Tasks 8, 10); Readium-CSS-style user-settings injection (USER > publisher via !important, publisher-styles honored otherwise) ✔ (Task 8 bridge `getCSS`); process-kill recovery ✔ (Task 8 `webViewWebContentProcessDidTerminate` + ready-handler resend); Early-M2 tickets ✔ (Tasks 1–4). Deliberately out of M2 scope per the spec's build order: annotations/selection, in-book search, MOBI (M3/M5); per-book settings; publisher-styles toggle UI (the mechanism exists in getCSS's two-slot form).
- **Recorded deviations:** whole-epub serving instead of per-resource unzip (justified at the top of Phase B); Locator field `spineIndex` alongside the spec's `spineHref` (both carried; index is what foliate-js round-trips natively); `progressionInChapter` currently null from the bridge (renderer-internal; display-only field, documented).
- **Type consistency check:** `ReaderSettings.Flow` string values match bridge's `s.flow === 'scrolled'` comparison (Codable encodes the raw string) ✔; `BookScheme.scheme` = "iqra-book" matches bridge fetch relative URLs (same-origin, no scheme literal in JS) ✔; `saveLocator(json:totalProgression:bookID:formatID:)` used identically in Tasks 7/10 ✔; `TOCItem` Codable shape matches bridge `flattenTOC` output (label/href/subitems) ✔; Task 3's `ReconciliationSweep.run(paths:store:dbm:caches:)` — Task 10's view model already passes `caches` via `start()` (updated in Task 3) ✔.
- **Known risk points for the implementer:** SPM `.copy` resource directory layout (Tasks 5/6 tests define the contract, lookups adapt); WKWebView viability under `swift test` (Task 8 Step 5 has the escalation path — never silent-skip); `zip.js` named exports in the vendored bundle (verified against upstream view.js's own destructuring import — same names); strict-concurrency diagnostics on the `Task.detached` capture in Task 4 (return-value pattern provided); `Stepper` with `%.1f` specifier needs `Text(String(format:))` if the interpolation form fails to compile — mechanical fix.

## Execution

Plan complete. Execute with superpowers:subagent-driven-development (fresh subagent per task, review between tasks) or superpowers:executing-plans (inline with checkpoints).
