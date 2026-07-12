# M1 — Catalogue Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working library app skeleton: GRDB catalogue with the full spec schema, crash-safe import pipeline for EPUB and PDF (sniff → classify → extract → dedupe → stage/rename/insert-last), sidecars, reconciliation sweep, FTS metadata search, and a minimal SwiftUI library UI on macOS + iOS.

**Architecture:** One SPM package (`Iqra`) with library targets `IqraCore` (pure value types, zero deps) and `IqraLibrary` (GRDB catalogue + import pipeline). Module boundaries from the spec are enforced at the *target* level — IqraLibrary depends on IqraCore only; IqraReader arrives in M2. The app shell is an XcodeGen-generated project consuming the package. Spec: `docs/superpowers/specs/2026-07-11-iqra-architecture-design.md`.

**Tech Stack:** Swift 5.10, SwiftUI, GRDB.swift 7.x (SQLite/WAL/FTS5), ZIPFoundation (EPUB containers), PDFKit (PDF metadata/covers), XcodeGen (app project generation).

## Global Constraints

- Deployment floors: **iOS 17.0 / macOS 14.0** (locked at planning; spec allowed raising).
- Swift tools version: **5.10**.
- Runtime dependencies allowed in M1: **GRDB.swift** and **ZIPFoundation** only. PDFKit/CoreGraphics/CryptoKit are system frameworks. XcodeGen is a build-time tool, never a dependency.
- Package boundary rule (spec "System overview"): `IqraCore` imports nothing but Foundation. `IqraLibrary` never imports UI or reader code.
- Every synced-table row insert/update goes through the apply-sequence stamp (spec "three clocks"): monotonic `INTEGER`, incremented on every accepted change.
- Managed library layout (spec "Disk layout"): `<libraryRoot>/Books/<bookUUID>/` containing `<formatUUID>.<ext>`, `metadata.json`, `cover.jpg`. Staging at `<libraryRoot>/Books/.staging/<bookUUID>/`.
- Import DB row is committed **last**, after the atomic folder rename (spec "Crash-safe import protocol").
- DRM-free only: EPUB with `META-INF/encryption.xml` (non-font-obfuscation) and encrypted PDFs are **quarantined**, not imported.
- All tests must run headless via `swift test` on macOS. The app target builds with `xcodebuild` but has no test gate in M1 (its logic lives in the tested packages).
- Commit after every task's final step. Conventional-commit style subjects (`feat:`, `test:`, `chore:`).

## File Structure

```
Package.swift                          — SPM manifest: IqraCore, IqraLibrary + test targets
Sources/IqraCore/
  FormatType.swift                     — format enum + sniffing result vocabulary
  ExtractedMetadata.swift              — extractor output value type (+ Contributor, BookIdentifier)
  ImportOutcome.swift                  — classification / dedupe decision vocabulary
Sources/IqraLibrary/
  Database/DatabaseManager.swift       — open catalogue + attached FTS db, migrations, applySequence
  Database/Records.swift               — GRDB record structs mirroring the schema
  Database/LibraryStore.swift          — typed queries: insertBook, fetch, search (FTS), observation
  Import/FormatSniffer.swift           — magic-byte sniffing
  Import/EPUBMetadataExtractor.swift   — container.xml → OPF → metadata + cover + DRM check
  Import/PDFMetadataExtractor.swift    — PDFKit info dict + first-page cover + encryption check
  Import/ThumbnailPipeline.swift       — 2 fixed-size JPEG thumbnails into Caches
  Import/Sidecar.swift                 — RWPM-shaped metadata.json encode/decode
  Import/ImportPipeline.swift          — the crash-safe orchestrator + dedupe ladder
  Import/ReconciliationSweep.swift     — startup invariants (staging, orphans, missing)
  LibraryPaths.swift                   — all filesystem layout knowledge in one place
Tests/IqraCoreTests/FormatTypeTests.swift
Tests/IqraLibraryTests/
  DatabaseManagerTests.swift
  RecordsTests.swift
  FormatSnifferTests.swift
  EPUBMetadataExtractorTests.swift
  PDFMetadataExtractorTests.swift
  ThumbnailPipelineTests.swift
  SidecarTests.swift
  ImportPipelineTests.swift
  ReconciliationSweepTests.swift
  LibraryStoreTests.swift
  Support/Fixtures.swift               — programmatic EPUB/PDF fixture builders (no binary fixtures)
App/project.yml                        — XcodeGen manifest (iqra app, iOS+macOS)
App/Sources/IqraApp.swift              — @main App
App/Sources/LibraryView.swift          — grid, search field, import button, quarantine sheet
```

---

### Task 1: Package scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/IqraCore/FormatType.swift`
- Test: `Tests/IqraCoreTests/FormatTypeTests.swift`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `enum FormatType: String, Codable, Sendable { case epub, pdf, cbz, cbr, mobi }` with `var fileExtension: String`; targets `IqraCore`, `IqraLibrary` that later tasks add files into.

- [ ] **Step 1: Write the manifest**

```swift
// Package.swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Iqra",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "IqraCore", targets: ["IqraCore"]),
        .library(name: "IqraLibrary", targets: ["IqraLibrary"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(name: "IqraCore"),
        .target(
            name: "IqraLibrary",
            dependencies: [
                "IqraCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(name: "IqraCoreTests", dependencies: ["IqraCore"]),
        .testTarget(name: "IqraLibraryTests", dependencies: ["IqraLibrary"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/IqraCoreTests/FormatTypeTests.swift
import XCTest
import IqraCore

final class FormatTypeTests: XCTestCase {
    func testFileExtensions() {
        XCTAssertEqual(FormatType.epub.fileExtension, "epub")
        XCTAssertEqual(FormatType.pdf.fileExtension, "pdf")
        XCTAssertEqual(FormatType.cbz.fileExtension, "cbz")
        XCTAssertEqual(FormatType.cbr.fileExtension, "cbr")
        XCTAssertEqual(FormatType.mobi.fileExtension, "mobi")
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(FormatType.epub)
        XCTAssertEqual(try JSONDecoder().decode(FormatType.self, from: data), .epub)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter FormatTypeTests`
Expected: FAIL — `cannot find 'FormatType'` (compile error counts as the failing state).

- [ ] **Step 4: Write minimal implementation**

```swift
// Sources/IqraCore/FormatType.swift
/// A supported (DRM-free) book container format.
public enum FormatType: String, Codable, Sendable, CaseIterable {
    case epub, pdf, cbz, cbr, mobi

    public var fileExtension: String { rawValue }
}
```

Also create an empty anchor so `IqraLibrary` compiles:

```swift
// Sources/IqraLibrary/LibraryPaths.swift  (fleshed out in Task 8)
import Foundation
import IqraCore

/// All knowledge of the managed-library filesystem layout. Placeholder body grows in Task 8.
public struct LibraryPaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
}
```

- [ ] **Step 5: Run tests to verify pass**

Run: `swift test`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat: SPM scaffold with IqraCore/IqraLibrary targets and FormatType"
```

---

### Task 2: IqraCore metadata vocabulary

**Files:**
- Create: `Sources/IqraCore/ExtractedMetadata.swift`
- Create: `Sources/IqraCore/ImportOutcome.swift`
- Test: `Tests/IqraCoreTests/ExtractedMetadataTests.swift`

**Interfaces:**
- Consumes: `FormatType` (Task 1)
- Produces (used by every extractor and the pipeline):

```swift
public struct Contributor: Codable, Equatable, Sendable { public let name: String; public let sortName: String; public let role: ContributorRole }
public enum ContributorRole: String, Codable, Sendable { case author, translator, narrator, editor }
public struct BookIdentifier: Codable, Equatable, Sendable { public let type: String; public let value: String }
public struct ExtractedMetadata: Codable, Equatable, Sendable {
    public let title: String, titleSort: String, language: String?, publisher: String?, bookDescription: String?
    public let contributors: [Contributor], identifiers: [BookIdentifier]
    public init(title:titleSort:language:publisher:bookDescription:contributors:identifiers:)
}
public enum ImportRejection: String, Codable, Sendable { case drmProtected, unsupportedFormat, corruptContainer }
public enum DedupeDecision: Equatable, Sendable { case newBook; case hydrate(formatID: UUID); case skipExactDuplicate(formatID: UUID); case askIdentifierMatch(existingBookID: UUID) }
public func makeTitleSort(_ title: String, language: String?) -> String
```

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IqraCoreTests/ExtractedMetadataTests.swift
import XCTest
import IqraCore

final class ExtractedMetadataTests: XCTestCase {
    func testTitleSortStripsLeadingArticleEnglish() {
        XCTAssertEqual(makeTitleSort("The Client", language: "en"), "Client, The")
        XCTAssertEqual(makeTitleSort("A Wizard of Earthsea", language: "en"), "Wizard of Earthsea, A")
        XCTAssertEqual(makeTitleSort("An Instance", language: "en"), "Instance, An")
    }

    func testTitleSortLeavesNonArticleAndUnknownLanguageAlone() {
        XCTAssertEqual(makeTitleSort("Their Eyes", language: "en"), "Their Eyes")
        XCTAssertEqual(makeTitleSort("The Client", language: "fr"), "The Client")
        XCTAssertEqual(makeTitleSort("The Client", language: nil), "Client, The")  // default English behavior
    }

    func testMetadataCodableRoundTrip() throws {
        let m = ExtractedMetadata(
            title: "T", titleSort: "T", language: "en", publisher: "P", bookDescription: nil,
            contributors: [Contributor(name: "Ursula K. Le Guin", sortName: "Le Guin, Ursula K.", role: .author)],
            identifiers: [BookIdentifier(type: "isbn", value: "9780141354491")]
        )
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(ExtractedMetadata.self, from: data), m)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ExtractedMetadataTests`
Expected: FAIL — `cannot find 'makeTitleSort'`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/IqraCore/ExtractedMetadata.swift
import Foundation

public enum ContributorRole: String, Codable, Sendable {
    case author, translator, narrator, editor
}

public struct Contributor: Codable, Equatable, Sendable {
    public let name: String
    public let sortName: String
    public let role: ContributorRole
    public init(name: String, sortName: String, role: ContributorRole) {
        self.name = name; self.sortName = sortName; self.role = role
    }
}

public struct BookIdentifier: Codable, Equatable, Sendable {
    public let type: String   // open bag: "isbn", "asin", "uuid", ... never a fixed column (spec)
    public let value: String
    public init(type: String, value: String) { self.type = type; self.value = value }
}

public struct ExtractedMetadata: Codable, Equatable, Sendable {
    public let title: String
    public let titleSort: String
    public let language: String?
    public let publisher: String?
    public let bookDescription: String?
    public let contributors: [Contributor]
    public let identifiers: [BookIdentifier]

    public init(title: String, titleSort: String, language: String?, publisher: String?,
                bookDescription: String?, contributors: [Contributor], identifiers: [BookIdentifier]) {
        self.title = title; self.titleSort = titleSort; self.language = language
        self.publisher = publisher; self.bookDescription = bookDescription
        self.contributors = contributors; self.identifiers = identifiers
    }
}

/// Stored sort key, computed once at import (spec: "never collate in queries").
/// English-only article stripping in M1; other languages pass through.
public func makeTitleSort(_ title: String, language: String?) -> String {
    let lang = language?.lowercased().prefix(2) ?? "en"
    guard lang == "en" else { return title }
    for article in ["The ", "A ", "An "] where title.hasPrefix(article) {
        let rest = String(title.dropFirst(article.count))
        return "\(rest), \(article.trimmingCharacters(in: .whitespaces))"
    }
    return title
}
```

```swift
// Sources/IqraCore/ImportOutcome.swift
import Foundation

/// Why the classify stage refused a file (spec: quarantine with user-facing states).
public enum ImportRejection: String, Codable, Sendable {
    case drmProtected, unsupportedFormat, corruptContainer
}

/// Result of the dedupe ladder (spec "Import pipeline" stage 5).
public enum DedupeDecision: Equatable, Sendable {
    case newBook
    case hydrate(formatID: UUID)            // hash matches a Format whose binary is missing locally
    case skipExactDuplicate(formatID: UUID) // hash matches and binary present
    case askIdentifierMatch(existingBookID: UUID) // surfaced to the user, never silent
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter ExtractedMetadataTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/IqraCore Tests/IqraCoreTests
git commit -m "feat: core metadata vocabulary (contributors, identifiers, title sort, import outcomes)"
```

---

### Task 3: DatabaseManager — catalogue + attached FTS db, migration v1, apply sequence

**Files:**
- Create: `Sources/IqraLibrary/Database/DatabaseManager.swift`
- Test: `Tests/IqraLibraryTests/DatabaseManagerTests.swift`

**Interfaces:**
- Consumes: GRDB.
- Produces:

```swift
public final class DatabaseManager: Sendable {
    public let writer: DatabaseWriter                   // DatabasePool (WAL)
    public init(catalogueURL: URL, ftsURL: URL) throws  // opens, attaches FTS db as schema "fts", migrates
    public static func inMemory() throws -> DatabaseManager  // for tests (DatabaseQueue + temp fts file)
    public func nextApplySequence(_ db: Database) throws -> Int64  // increments and returns
}
```

The full spec schema lands in migration `v1` — including tables M1 doesn't populate yet (`reading_state`, `annotation`, `field_lock`, `collection*`) so the schema is locked early and later milestones only add migrations.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IqraLibraryTests/DatabaseManagerTests.swift
import XCTest
import GRDB
@testable import IqraLibrary

final class DatabaseManagerTests: XCTestCase {
    func testMigrationCreatesFullSchema() throws {
        let dbm = try DatabaseManager.inMemory()
        try dbm.writer.read { db in
            for table in ["book", "contributor", "book_contributor", "series", "tag", "book_tag",
                          "identifier", "format", "format_local", "collection", "collection_book",
                          "field_lock", "reading_state", "annotation", "import_item", "apply_sequence"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
            // FTS table lives in the attached "fts" schema
            let n = try Int.fetchOne(db, sql:
                "SELECT count(*) FROM fts.sqlite_master WHERE name = 'book_fts'")
            XCTAssertEqual(n, 1)
        }
    }

    func testApplySequenceIsMonotonic() throws {
        let dbm = try DatabaseManager.inMemory()
        let (a, b) = try dbm.writer.write { db in
            (try dbm.nextApplySequence(db), try dbm.nextApplySequence(db))
        }
        XCTAssertEqual(b, a + 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DatabaseManagerTests`
Expected: FAIL — `cannot find 'DatabaseManager'`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/IqraLibrary/Database/DatabaseManager.swift
import Foundation
import GRDB

/// Owns the catalogue database (WAL) with the FTS index ATTACHed as a separate,
/// rebuildable file (spec: calibre's pattern). All schema lives in migrations.
public final class DatabaseManager: @unchecked Sendable {
    public let writer: any DatabaseWriter

    public convenience init(catalogueURL: URL, ftsURL: URL) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "ATTACH DATABASE ? AS fts", arguments: [ftsURL.path])
        }
        let pool = try DatabasePool(path: catalogueURL.path, configuration: config)
        try self.init(writer: pool)
    }

    /// Test convenience: in-memory catalogue with a throwaway on-disk FTS file
    /// (ATTACH needs a path; the temp file is per-instance).
    public static func inMemory() throws -> DatabaseManager {
        let ftsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fts-\(UUID().uuidString).sqlite")
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "ATTACH DATABASE ? AS fts", arguments: [ftsURL.path])
        }
        let queue = try DatabaseQueue(configuration: config)
        return try DatabaseManager(writer: queue)
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public func nextApplySequence(_ db: Database) throws -> Int64 {
        try db.execute(sql: "UPDATE apply_sequence SET value = value + 1")
        return try Int64.fetchOne(db, sql: "SELECT value FROM apply_sequence")!
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            // ---- catalogue-local apply sequence (spec "three clocks") ----
            try db.execute(sql: "CREATE TABLE apply_sequence (value INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO apply_sequence (value) VALUES (0)")

            try db.create(table: "book") { t in
                t.primaryKey("id", .text)                       // UUID string
                t.column("title", .text).notNull()
                t.column("titleSort", .text).notNull().indexed()
                t.column("bookDescription", .text)
                t.column("publisher", .text)
                t.column("pubDate", .text)
                t.column("language", .text)
                t.column("seriesId", .text).references("series")
                t.column("seriesIndex", .double)                // REAL: fractional indices
                t.column("wantToRead", .boolean).notNull().defaults(to: false)
                t.column("isFinished", .boolean).notNull().defaults(to: false)
                t.column("dateFinished", .datetime)
                t.column("lastOpenedAt", .datetime)
                t.column("addedAt", .datetime).notNull()
                t.column("applySeq", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false) // permanent tombstone
            }
            try db.create(table: "series") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("sortName", .text).notNull()
                t.column("applySeq", .integer).notNull()
            }
            try db.create(table: "contributor") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("sortName", .text).notNull()
                t.column("applySeq", .integer).notNull()
            }
            try db.create(table: "book_contributor") { t in
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("contributorId", .text).notNull().indexed().references("contributor")
                t.column("role", .text).notNull()               // author/translator/narrator/editor
                t.column("ordinal", .integer).notNull()
            }
            try db.create(table: "tag") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().unique()
                t.column("applySeq", .integer).notNull()
            }
            try db.create(table: "book_tag") { t in
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("tagId", .text).notNull().indexed().references("tag")
            }
            try db.create(table: "identifier") { t in         // open bag, never an isbn column
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("value", .text).notNull().indexed()
            }
            try db.create(table: "format") { t in
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("formatType", .text).notNull()
                t.column("originalFileName", .text).notNull()   // export/reveal only; stored file is <formatUUID>.<ext>
                t.column("byteSize", .integer).notNull()
                t.column("contentHash", .text).notNull().indexed() // SHA-256 hex; identity + dedupe + merge key
                t.column("addedAt", .datetime).notNull()
                t.column("applySeq", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "format_local") { t in        // per-device availability; NEVER synced
                t.primaryKey("formatId", .text)
                t.column("present", .boolean).notNull()
                t.column("localVerifiedAt", .datetime)
                t.column("missing", .boolean).notNull().defaults(to: false) // row exists but folder lost (reconciliation)
            }
            try db.create(table: "collection") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("smartRule", .text)                    // JSON; NULL = manual
                t.column("applySeq", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "collection_book") { t in     // first-class synced membership record
                t.primaryKey("id", .text)
                t.column("collectionId", .text).notNull().indexed().references("collection")
                t.column("bookId", .text).notNull().indexed().references("book")
                t.column("orderKey", .text).notNull()           // fractional / LexoRank-style
                t.column("applySeq", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "field_lock") { t in          // one record per locked field (reviewed: no JSON blob)
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("field", .text).notNull()
                t.column("locked", .boolean).notNull()
                t.column("applySeq", .integer).notNull()
                t.uniqueKey(["bookId", "field"])
            }
            try db.create(table: "reading_state") { t in       // per (book, format); device tags live INSIDE locator JSON
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("formatId", .text).notNull().indexed().references("format")
                t.column("currentLocator", .text)               // JSON {locator, deviceId, deviceName, localCounter, advisoryTime}
                t.column("candidates", .text).notNull().defaults(to: "[]") // durable conflict candidates, same shape
                t.column("highWaterMark", .double).notNull().defaults(to: 0)
                t.column("applySeq", .integer).notNull()
                t.uniqueKey(["bookId", "formatId"])
            }
            try db.create(table: "annotation") { t in
                t.primaryKey("id", .text)
                t.column("bookId", .text).notNull().indexed().references("book", onDelete: .cascade)
                t.column("formatId", .text).notNull().references("format")
                t.column("kind", .text).notNull()               // highlight/note/bookmark
                t.column("locator", .text).notNull()            // JSON: range CFI or PDF quads
                t.column("color", .text)
                t.column("noteText", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("applySeq", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false) // tombstone: monotonic, never GCed
            }
            try db.create(table: "import_item") { t in         // local-only durable import/quarantine state
                t.primaryKey("id", .text)
                t.column("sourceBookmark", .blob)               // security-scoped bookmark
                t.column("sourceDisplayPath", .text).notNull()
                t.column("status", .text).notNull()             // pending/importing/quarantined/failed/done
                t.column("rejection", .text)                    // ImportRejection raw value
                t.column("message", .text)
                t.column("attemptCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("bookId", .text)                       // nullable resulting book
            }
            // ---- FTS5 metadata index in the ATTACHed db (rebuildable) ----
            try db.execute(sql: """
                CREATE VIRTUAL TABLE fts.book_fts USING fts5(
                    bookId UNINDEXED, title, authors, series, tags, description,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """)
        }
        return m
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter DatabaseManagerTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/IqraLibrary/Database Tests/IqraLibraryTests/DatabaseManagerTests.swift
git commit -m "feat: catalogue schema v1 with attached FTS db and apply sequence"
```

---

### Task 4: Record types + LibraryStore.insertBook

**Files:**
- Create: `Sources/IqraLibrary/Database/Records.swift`
- Create: `Sources/IqraLibrary/Database/LibraryStore.swift`
- Test: `Tests/IqraLibraryTests/RecordsTests.swift`

**Interfaces:**
- Consumes: `DatabaseManager` (Task 3), `ExtractedMetadata`/`Contributor`/`BookIdentifier`/`FormatType` (Tasks 1–2).
- Produces:

```swift
public struct BookRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable
    // id: String(UUID), title, titleSort, bookDescription, publisher, pubDate, language,
    // seriesId, seriesIndex, wantToRead, isFinished, dateFinished, lastOpenedAt, addedAt, applySeq, deleted
public struct FormatRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable
    // id, bookId, formatType, originalFileName, byteSize, contentHash, addedAt, applySeq, deleted
public struct ImportItemRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable
    // id, sourceBookmark, sourceDisplayPath, status, rejection, message, attemptCount, createdAt, updatedAt, bookId

public final class LibraryStore: Sendable {
    public init(dbm: DatabaseManager)
    /// Inserts book + contributors + identifiers + format + format_local(present) + FTS row, all stamped
    /// with fresh apply sequences, in ONE transaction. Returns the ids.
    @discardableResult
    public func insertBook(metadata: ExtractedMetadata, formatType: FormatType,
                           originalFileName: String, byteSize: Int64, contentHash: String,
                           bookID: UUID, formatID: UUID) throws -> (bookID: UUID, formatID: UUID)
    public func fetchBook(_ id: UUID) throws -> BookRecord?
    public func fetchFormats(bookID: UUID) throws -> [FormatRecord]
    public func fetchAuthors(bookID: UUID) throws -> [String]  // ordered by ordinal
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IqraLibraryTests/RecordsTests.swift
import XCTest
import IqraCore
@testable import IqraLibrary

final class RecordsTests: XCTestCase {
    func makeMetadata() -> ExtractedMetadata {
        ExtractedMetadata(
            title: "The Dispossessed", titleSort: makeTitleSort("The Dispossessed", language: "en"),
            language: "en", publisher: "Harper", bookDescription: "An ambiguous utopia.",
            contributors: [Contributor(name: "Ursula K. Le Guin", sortName: "Le Guin, Ursula K.", role: .author)],
            identifiers: [BookIdentifier(type: "isbn", value: "9780060512750")]
        )
    }

    func testInsertBookRoundTrip() throws {
        let dbm = try DatabaseManager.inMemory()
        let store = LibraryStore(dbm: dbm)
        let bookID = UUID(), formatID = UUID()
        try store.insertBook(metadata: makeMetadata(), formatType: .epub,
                             originalFileName: "dispossessed.epub", byteSize: 1234,
                             contentHash: "abc123", bookID: bookID, formatID: formatID)

        let book = try XCTUnwrap(store.fetchBook(bookID))
        XCTAssertEqual(book.title, "The Dispossessed")
        XCTAssertEqual(book.titleSort, "Dispossessed, The")
        XCTAssertGreaterThan(book.applySeq, 0)

        let formats = try store.fetchFormats(bookID: bookID)
        XCTAssertEqual(formats.map(\.contentHash), ["abc123"])
        XCTAssertEqual(try store.fetchAuthors(bookID: bookID), ["Ursula K. Le Guin"])
    }

    func testContributorsAreDeduplicatedAcrossBooks() throws {
        let dbm = try DatabaseManager.inMemory()
        let store = LibraryStore(dbm: dbm)
        try store.insertBook(metadata: makeMetadata(), formatType: .epub, originalFileName: "a.epub",
                             byteSize: 1, contentHash: "h1", bookID: UUID(), formatID: UUID())
        try store.insertBook(metadata: makeMetadata(), formatType: .epub, originalFileName: "b.epub",
                             byteSize: 2, contentHash: "h2", bookID: UUID(), formatID: UUID())
        let count = try dbm.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM contributor")!
        }
        XCTAssertEqual(count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecordsTests`
Expected: FAIL — `cannot find 'LibraryStore'`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/IqraLibrary/Database/Records.swift
import Foundation
import GRDB

public struct BookRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "book"
    public var id: String
    public var title: String
    public var titleSort: String
    public var bookDescription: String?
    public var publisher: String?
    public var pubDate: String?
    public var language: String?
    public var seriesId: String?
    public var seriesIndex: Double?
    public var wantToRead: Bool
    public var isFinished: Bool
    public var dateFinished: Date?
    public var lastOpenedAt: Date?
    public var addedAt: Date
    public var applySeq: Int64
    public var deleted: Bool
}

public struct FormatRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "format"
    public var id: String
    public var bookId: String
    public var formatType: String
    public var originalFileName: String
    public var byteSize: Int64
    public var contentHash: String
    public var addedAt: Date
    public var applySeq: Int64
    public var deleted: Bool
}

public struct ImportItemRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "import_item"
    public var id: String
    public var sourceBookmark: Data?
    public var sourceDisplayPath: String
    public var status: String        // pending/importing/quarantined/failed/done
    public var rejection: String?    // ImportRejection rawValue
    public var message: String?
    public var attemptCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var bookId: String?
}
```

```swift
// Sources/IqraLibrary/Database/LibraryStore.swift
import Foundation
import GRDB
import IqraCore

public final class LibraryStore: @unchecked Sendable {
    let dbm: DatabaseManager
    public init(dbm: DatabaseManager) { self.dbm = dbm }

    @discardableResult
    public func insertBook(metadata: ExtractedMetadata, formatType: FormatType,
                           originalFileName: String, byteSize: Int64, contentHash: String,
                           bookID: UUID, formatID: UUID) throws -> (bookID: UUID, formatID: UUID) {
        try dbm.writer.write { db in
            let now = Date()
            let bookSeq = try dbm.nextApplySequence(db)
            try BookRecord(
                id: bookID.uuidString, title: metadata.title, titleSort: metadata.titleSort,
                bookDescription: metadata.bookDescription, publisher: metadata.publisher,
                pubDate: nil, language: metadata.language, seriesId: nil, seriesIndex: nil,
                wantToRead: false, isFinished: false, dateFinished: nil, lastOpenedAt: nil,
                addedAt: now, applySeq: bookSeq, deleted: false
            ).insert(db)

            for (ordinal, c) in metadata.contributors.enumerated() {
                let contributorId: String
                if let existing = try String.fetchOne(
                    db, sql: "SELECT id FROM contributor WHERE name = ?", arguments: [c.name]) {
                    contributorId = existing
                } else {
                    contributorId = UUID().uuidString
                    let seq = try dbm.nextApplySequence(db)
                    try db.execute(
                        sql: "INSERT INTO contributor (id, name, sortName, applySeq) VALUES (?, ?, ?, ?)",
                        arguments: [contributorId, c.name, c.sortName, seq])
                }
                try db.execute(
                    sql: """
                    INSERT INTO book_contributor (id, bookId, contributorId, role, ordinal)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [UUID().uuidString, bookID.uuidString, contributorId, c.role.rawValue, ordinal])
            }

            for ident in metadata.identifiers {
                try db.execute(
                    sql: "INSERT INTO identifier (id, bookId, type, value) VALUES (?, ?, ?, ?)",
                    arguments: [UUID().uuidString, bookID.uuidString, ident.type, ident.value])
            }

            let formatSeq = try dbm.nextApplySequence(db)
            try FormatRecord(
                id: formatID.uuidString, bookId: bookID.uuidString, formatType: formatType.rawValue,
                originalFileName: originalFileName, byteSize: byteSize, contentHash: contentHash,
                addedAt: now, applySeq: formatSeq, deleted: false
            ).insert(db)
            try db.execute(
                sql: "INSERT INTO format_local (formatId, present, localVerifiedAt, missing) VALUES (?, 1, ?, 0)",
                arguments: [formatID.uuidString, now])

            let authors = metadata.contributors.filter { $0.role == .author }.map(\.name)
            try db.execute(
                sql: """
                INSERT INTO fts.book_fts (bookId, title, authors, series, tags, description)
                VALUES (?, ?, ?, '', '', ?)
                """,
                arguments: [bookID.uuidString, metadata.title,
                            authors.joined(separator: ", "), metadata.bookDescription ?? ""])
            return (bookID, formatID)
        }
    }

    public func fetchBook(_ id: UUID) throws -> BookRecord? {
        try dbm.writer.read { db in try BookRecord.fetchOne(db, key: id.uuidString) }
    }

    public func fetchFormats(bookID: UUID) throws -> [FormatRecord] {
        try dbm.writer.read { db in
            try FormatRecord
                .filter(Column("bookId") == bookID.uuidString && Column("deleted") == false)
                .fetchAll(db)
        }
    }

    public func fetchAuthors(bookID: UUID) throws -> [String] {
        try dbm.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT c.name FROM contributor c
                JOIN book_contributor bc ON bc.contributorId = c.id
                WHERE bc.bookId = ? AND bc.role = 'author'
                ORDER BY bc.ordinal
                """, arguments: [bookID.uuidString])
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter RecordsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/IqraLibrary/Database Tests/IqraLibraryTests/RecordsTests.swift
git commit -m "feat: record types and transactional insertBook with FTS row"
```

---

### Task 5: Format sniffer (magic bytes)

**Files:**
- Create: `Sources/IqraLibrary/Import/FormatSniffer.swift`
- Test: `Tests/IqraLibraryTests/FormatSnifferTests.swift`

**Interfaces:**
- Consumes: `FormatType` (Task 1).
- Produces:

```swift
public enum SniffResult: Equatable, Sendable {
    case recognized(FormatType)
    case unrecognized
}
public enum FormatSniffer {
    /// Sniffs by magic bytes, never by extension (spec stage 1).
    public static func sniff(fileURL: URL) throws -> SniffResult
}
```

Rules: `%PDF` prefix → pdf. `PK\x03\x04` zip → epub if the entry `mimetype` exists with content `application/epub+zip`, else cbz. `Rar!` → cbr. `BOOKMOBI` at byte offset 60 → mobi. Anything else → unrecognized.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IqraLibraryTests/FormatSnifferTests.swift
import XCTest
import IqraCore
import ZIPFoundation
@testable import IqraLibrary

final class FormatSnifferTests: XCTestCase {
    func tempFile(_ data: Data, ext: String = "bin") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: url)
        return url
    }

    func zipFile(entries: [(name: String, data: Data)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".zip")
        let archive = try Archive(url: url, accessMode: .create)
        for e in entries {
            try archive.addEntry(with: e.name, type: .file,
                                 uncompressedSize: Int64(e.data.count),
                                 provider: { position, size in
                                     e.data.subdata(in: Int(position)..<Int(position) + size)
                                 })
        }
        return url
    }

    func testSniffPDF() throws {
        let url = try tempFile(Data("%PDF-1.7 rest".utf8))
        XCTAssertEqual(try FormatSniffer.sniff(fileURL: url), .recognized(.pdf))
    }

    func testSniffEPUB() throws {
        let url = try zipFile(entries: [("mimetype", Data("application/epub+zip".utf8))])
        XCTAssertEqual(try FormatSniffer.sniff(fileURL: url), .recognized(.epub))
    }

    func testSniffZipWithoutMimetypeIsCBZ() throws {
        let url = try zipFile(entries: [("page001.png", Data([0x89, 0x50]))])
        XCTAssertEqual(try FormatSniffer.sniff(fileURL: url), .recognized(.cbz))
    }

    func testSniffRAR() throws {
        let url = try tempFile(Data("Rar!\u{05}\u{07}".utf8))
        XCTAssertEqual(try FormatSniffer.sniff(fileURL: url), .recognized(.cbr))
    }

    func testSniffMOBI() throws {
        var data = Data(count: 60)
        data.append(Data("BOOKMOBI".utf8))
        data.append(Data(count: 8))
        let url = try tempFile(data)
        XCTAssertEqual(try FormatSniffer.sniff(fileURL: url), .recognized(.mobi))
    }

    func testUnrecognized() throws {
        let url = try tempFile(Data("hello world".utf8), ext: "epub") // extension must NOT matter
        XCTAssertEqual(try FormatSniffer.sniff(fileURL: url), .unrecognized)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FormatSnifferTests`
Expected: FAIL — `cannot find 'FormatSniffer'`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/IqraLibrary/Import/FormatSniffer.swift
import Foundation
import IqraCore
import ZIPFoundation

public enum SniffResult: Equatable, Sendable {
    case recognized(FormatType)
    case unrecognized
}

public enum FormatSniffer {
    public static func sniff(fileURL: URL) throws -> SniffResult {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 68) ?? Data()

        if head.starts(with: Data("%PDF".utf8)) { return .recognized(.pdf) }
        if head.starts(with: Data("Rar!".utf8)) { return .recognized(.cbr) }
        if head.count >= 68, head[60..<68] == Data("BOOKMOBI".utf8) { return .recognized(.mobi) }
        if head.starts(with: Data([0x50, 0x4B, 0x03, 0x04])) {
            // zip: EPUB iff the mimetype entry says so; otherwise treat as comic archive
            guard let archive = try? Archive(url: fileURL, accessMode: .read) else { return .unrecognized }
            if let entry = archive["mimetype"] {
                var content = Data()
                _ = try? archive.extract(entry) { content.append($0) }
                if String(decoding: content, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" {
                    return .recognized(.epub)
                }
            }
            return .recognized(.cbz)
        }
        return .unrecognized
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter FormatSnifferTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/IqraLibrary/Import Tests/IqraLibraryTests/FormatSnifferTests.swift
git commit -m "feat: magic-byte format sniffer"
```

---

### Task 6: EPUB fixture builder + metadata extractor (with DRM classify)

**Files:**
- Create: `Tests/IqraLibraryTests/Support/Fixtures.swift`
- Create: `Sources/IqraLibrary/Import/EPUBMetadataExtractor.swift`
- Test: `Tests/IqraLibraryTests/EPUBMetadataExtractorTests.swift`

**Interfaces:**
- Consumes: `ExtractedMetadata`, `ImportRejection`, `makeTitleSort` (Task 2).
- Produces:

```swift
public enum ExtractionResult: Equatable, Sendable {
    case extracted(ExtractedMetadata, coverData: Data?)
    case rejected(ImportRejection)
}
public enum EPUBMetadataExtractor {
    public static func extract(fileURL: URL) -> ExtractionResult
}
// test support (internal to test target):
enum Fixtures {
    static func makeEPUB(title: String, author: String, isbn: String?, language: String,
                         coverJPEG: Data?, encrypted: Bool, dir: URL) throws -> URL
    static func makePDF(title: String?, author: String?, dir: URL) throws -> URL   // added in Task 7
    static func tinyJPEG() -> Data
}
```

- [ ] **Step 1: Write the fixture builder**

```swift
// Tests/IqraLibraryTests/Support/Fixtures.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

enum Fixtures {
    /// A 4x4 red JPEG rendered with CoreGraphics — no binary fixture files.
    static func tinyJPEG() -> Data {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func makeEPUB(title: String, author: String, isbn: String?, language: String = "en",
                         coverJPEG: Data? = nil, encrypted: Bool = false, dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".epub")
        let archive = try Archive(url: url, accessMode: .create)
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
        if encrypted {
            try add("META-INF/encryption.xml", """
                <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
                    <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
                  </EncryptedData>
                </encryption>
                """)
        }
        let coverManifest = coverJPEG != nil
            ? #"<item id="cover-image" href="cover.jpg" media-type="image/jpeg"/>"# : ""
        let coverMeta = coverJPEG != nil ? #"<meta name="cover" content="cover-image"/>"# : ""
        let isbnXML = isbn.map { #"<dc:identifier opf:scheme="ISBN">\#($0)</dc:identifier>"# } ?? ""
        try add("OEBPS/content.opf", """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(title)</dc:title>
                <dc:creator>\(author)</dc:creator>
                <dc:language>\(language)</dc:language>
                <dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier>
                \(isbnXML)
                <dc:description>Fixture description.</dc:description>
                \(coverMeta)
              </metadata>
              <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                \(coverManifest)
              </manifest>
              <spine><itemref idref="ch1"/></spine>
            </package>
            """)
        try add("OEBPS/ch1.xhtml", "<html><body><p>Hello.</p></body></html>")
        if let coverJPEG {
            try archive.addEntry(with: "OEBPS/cover.jpg", type: .file,
                                 uncompressedSize: Int64(coverJPEG.count),
                                 provider: { p, s in coverJPEG.subdata(in: Int(p)..<Int(p) + s) })
        }
        return url
    }
}
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/IqraLibraryTests/EPUBMetadataExtractorTests.swift
import XCTest
import IqraCore
@testable import IqraLibrary

final class EPUBMetadataExtractorTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func testExtractsMetadataAndCover() throws {
        let url = try Fixtures.makeEPUB(title: "The Left Hand of Darkness", author: "Ursula K. Le Guin",
                                        isbn: "9780441478125", coverJPEG: Fixtures.tinyJPEG(), dir: dir)
        guard case let .extracted(meta, coverData) = EPUBMetadataExtractor.extract(fileURL: url) else {
            return XCTFail("expected extraction")
        }
        XCTAssertEqual(meta.title, "The Left Hand of Darkness")
        XCTAssertEqual(meta.titleSort, "Left Hand of Darkness, The")
        XCTAssertEqual(meta.contributors.map(\.name), ["Ursula K. Le Guin"])
        XCTAssertEqual(meta.contributors.first?.role, .author)
        XCTAssertTrue(meta.identifiers.contains(BookIdentifier(type: "isbn", value: "9780441478125")))
        XCTAssertEqual(meta.language, "en")
        XCTAssertNotNil(coverData)
    }

    func testEncryptedEPUBIsRejectedAsDRM() throws {
        let url = try Fixtures.makeEPUB(title: "Locked", author: "X", isbn: nil,
                                        encrypted: true, dir: dir)
        XCTAssertEqual(EPUBMetadataExtractor.extract(fileURL: url), .rejected(.drmProtected))
    }

    func testGarbageZipIsRejectedAsCorrupt() throws {
        let url = dir.appendingPathComponent("bad.epub")
        try Data("PK\u{03}\u{04}garbage".utf8).write(to: url)
        XCTAssertEqual(EPUBMetadataExtractor.extract(fileURL: url), .rejected(.corruptContainer))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter EPUBMetadataExtractorTests`
Expected: FAIL — `cannot find 'EPUBMetadataExtractor'`.

- [ ] **Step 4: Write the implementation**

```swift
// Sources/IqraLibrary/Import/EPUBMetadataExtractor.swift
import Foundation
import IqraCore
import ZIPFoundation

public enum ExtractionResult: Equatable, Sendable {
    case extracted(ExtractedMetadata, coverData: Data?)
    case rejected(ImportRejection)
}

public enum EPUBMetadataExtractor {
    public static func extract(fileURL: URL) -> ExtractionResult {
        guard let archive = try? Archive(url: fileURL, accessMode: .read) else {
            return .rejected(.corruptContainer)
        }
        func read(_ path: String) -> Data? {
            guard let entry = archive[path] else { return nil }
            var data = Data()
            guard (try? archive.extract(entry) { data.append($0) }) != nil else { return nil }
            return data
        }
        // DRM check (spec: encryption.xml beyond font obfuscation → quarantine).
        if let enc = read("META-INF/encryption.xml") {
            let text = String(decoding: enc, as: UTF8.self)
            let fontOnly = text.contains("http://www.idpf.org/2008/embedding")
                || text.contains("http://ns.adobe.com/pdf/enc#RC")
            if !fontOnly { return .rejected(.drmProtected) }
        }
        guard let containerData = read("META-INF/container.xml"),
              let opfPath = OPFPathParser.parse(containerData),
              let opfData = read(opfPath) else {
            return .rejected(.corruptContainer)
        }
        let opf = OPFParser()
        guard let parsed = opf.parse(opfData) else { return .rejected(.corruptContainer) }

        var coverData: Data? = nil
        if let coverHref = parsed.coverHref {
            let opfDir = (opfPath as NSString).deletingLastPathComponent
            let coverPath = opfDir.isEmpty ? coverHref : opfDir + "/" + coverHref
            coverData = read(coverPath)
        }
        let metadata = ExtractedMetadata(
            title: parsed.title, titleSort: makeTitleSort(parsed.title, language: parsed.language),
            language: parsed.language, publisher: parsed.publisher,
            bookDescription: parsed.description,
            contributors: parsed.creators.map {
                Contributor(name: $0, sortName: makeAuthorSort($0), role: .author)
            },
            identifiers: parsed.identifiers)
        return .extracted(metadata, coverData: coverData)
    }

    /// "Ursula K. Le Guin" → "Le Guin, Ursula K." — naive last-token inversion, calibre's default method.
    static func makeAuthorSort(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard parts.count > 1, let last = parts.last else { return name }
        return "\(last), \(parts.dropLast().joined(separator: " "))"
    }
}

/// Finds the OPF rootfile path in container.xml.
enum OPFPathParser {
    static func parse(_ data: Data) -> String? {
        final class Delegate: NSObject, XMLParserDelegate {
            var path: String?
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                if name == "rootfile", path == nil { path = attributes["full-path"] }
            }
        }
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.path
    }
}

/// Minimal OPF (package document) metadata parser.
final class OPFParser: NSObject, XMLParserDelegate {
    struct Result {
        var title = ""
        var creators: [String] = []
        var language: String?
        var publisher: String?
        var description: String?
        var identifiers: [BookIdentifier] = []
        var coverHref: String?
    }
    private var result = Result()
    private var currentElement = ""
    private var currentText = ""
    private var currentScheme: String?
    private var coverImageID: String?
    private var manifestHrefByID: [String: String] = [:]

    func parse(_ data: Data) -> Result? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        guard parser.parse(), !result.title.isEmpty else { return nil }
        if let id = coverImageID { result.coverHref = manifestHrefByID[id] }
        return result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = name
        currentText = ""
        currentScheme = attributes["opf:scheme"] ?? attributes["scheme"]
        if name == "meta", attributes["name"] == "cover" { coverImageID = attributes["content"] }
        if name == "item", let id = attributes["id"], let href = attributes["href"] {
            manifestHrefByID[id] = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch name {
        case "title" where result.title.isEmpty: result.title = text
        case "creator": result.creators.append(text)
        case "language" where result.language == nil: result.language = text
        case "publisher": result.publisher = text
        case "description": result.description = text
        case "identifier":
            let scheme = (currentScheme ?? "").lowercased()
            if scheme == "isbn" {
                result.identifiers.append(BookIdentifier(type: "isbn", value: text))
            } else if text.lowercased().hasPrefix("urn:isbn:") {
                result.identifiers.append(BookIdentifier(type: "isbn", value: String(text.dropFirst(9))))
            } else {
                result.identifiers.append(BookIdentifier(type: "uuid", value: text))
            }
        default: break
        }
        currentText = ""
    }
}
```

- [ ] **Step 5: Run tests to verify pass**

Run: `swift test --filter EPUBMetadataExtractorTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/IqraLibrary/Import Tests/IqraLibraryTests
git commit -m "feat: EPUB metadata extractor with cover and DRM classification"
```

---

### Task 7: PDF metadata extractor

**Files:**
- Create: `Sources/IqraLibrary/Import/PDFMetadataExtractor.swift`
- Modify: `Tests/IqraLibraryTests/Support/Fixtures.swift` (add `makePDF`)
- Test: `Tests/IqraLibraryTests/PDFMetadataExtractorTests.swift`

**Interfaces:**
- Consumes: `ExtractionResult` (Task 6), PDFKit.
- Produces: `public enum PDFMetadataExtractor { public static func extract(fileURL: URL) -> ExtractionResult }` — cover is a first-page render; encrypted PDFs are `.rejected(.drmProtected)`; title falls back to filename stem when the info dict is empty.

- [ ] **Step 1: Add the PDF fixture builder**

Append to `Tests/IqraLibraryTests/Support/Fixtures.swift`:

```swift
    static func makePDF(title: String?, author: String?, dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        if let author { info[kCGPDFContextAuthor] = author }
        let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 160, height: 260))
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/IqraLibraryTests/PDFMetadataExtractorTests.swift
import XCTest
import IqraCore
@testable import IqraLibrary

final class PDFMetadataExtractorTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func testExtractsInfoDictAndRendersCover() throws {
        let url = try Fixtures.makePDF(title: "Design Patterns", author: "Gamma et al.", dir: dir)
        guard case let .extracted(meta, coverData) = PDFMetadataExtractor.extract(fileURL: url) else {
            return XCTFail("expected extraction")
        }
        XCTAssertEqual(meta.title, "Design Patterns")
        XCTAssertEqual(meta.contributors.map(\.name), ["Gamma et al."])
        let cover = try XCTUnwrap(coverData)
        XCTAssertGreaterThan(cover.count, 100) // a real JPEG render, not a stub
    }

    func testFallsBackToFilenameWhenNoTitle() throws {
        let url = try Fixtures.makePDF(title: nil, author: nil, dir: dir)
        guard case let .extracted(meta, _) = PDFMetadataExtractor.extract(fileURL: url) else {
            return XCTFail("expected extraction")
        }
        XCTAssertEqual(meta.title, url.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(meta.contributors.isEmpty)
    }

    func testGarbageIsRejectedAsCorrupt() throws {
        let url = dir.appendingPathComponent("bad.pdf")
        try Data("%PDF-1.7 not really".utf8).write(to: url)
        XCTAssertEqual(PDFMetadataExtractor.extract(fileURL: url), .rejected(.corruptContainer))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter PDFMetadataExtractorTests`
Expected: FAIL — `cannot find 'PDFMetadataExtractor'`.

- [ ] **Step 4: Write the implementation**

```swift
// Sources/IqraLibrary/Import/PDFMetadataExtractor.swift
import Foundation
import IqraCore
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum PDFMetadataExtractor {
    public static func extract(fileURL: URL) -> ExtractionResult {
        guard let doc = PDFDocument(url: fileURL), doc.pageCount > 0 else {
            return .rejected(.corruptContainer)
        }
        if doc.isEncrypted { return .rejected(.drmProtected) }

        let attrs = doc.documentAttributes ?? [:]
        let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? fileURL.deletingPathExtension().lastPathComponent
        let author = (attrs[PDFDocumentAttribute.authorAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        var coverData: Data? = nil
        if let page = doc.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let scale = 400 / max(bounds.width, 1)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                page.draw(with: .mediaBox, to: ctx)
                if let image = ctx.makeImage() {
                    let out = NSMutableData()
                    if let dest = CGImageDestinationCreateWithData(
                        out, UTType.jpeg.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, image, nil)
                        if CGImageDestinationFinalize(dest) { coverData = out as Data }
                    }
                }
            }
        }
        let metadata = ExtractedMetadata(
            title: title, titleSort: makeTitleSort(title, language: nil),
            language: nil, publisher: nil, bookDescription: nil,
            contributors: author.map {
                [Contributor(name: $0, sortName: EPUBMetadataExtractor.makeAuthorSort($0), role: .author)]
            } ?? [],
            identifiers: [])
        return .extracted(metadata, coverData: coverData)
    }
}
```

- [ ] **Step 5: Run tests to verify pass**

Run: `swift test --filter PDFMetadataExtractorTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/IqraLibrary/Import Tests/IqraLibraryTests
git commit -m "feat: PDF metadata extractor with first-page cover render"
```

---

### Task 8: LibraryPaths + thumbnail pipeline + metadata sidecar

**Files:**
- Modify: `Sources/IqraLibrary/LibraryPaths.swift`
- Create: `Sources/IqraLibrary/Import/ThumbnailPipeline.swift`
- Create: `Sources/IqraLibrary/Import/Sidecar.swift`
- Test: `Tests/IqraLibraryTests/ThumbnailPipelineTests.swift`, `Tests/IqraLibraryTests/SidecarTests.swift`

**Interfaces:**
- Consumes: `ExtractedMetadata`, `FormatType` (Tasks 1–2), fixture JPEG (Task 6).
- Produces:

```swift
public struct LibraryPaths: Sendable {
    public let root: URL
    public init(root: URL)
    public var booksDir: URL                              // root/Books
    public var stagingDir: URL                            // root/Books/.staging
    public func bookDir(_ bookID: UUID) -> URL            // root/Books/<uuid>
    public func stagingBookDir(_ bookID: UUID) -> URL     // root/Books/.staging/<uuid>
    public func formatFile(bookID: UUID, formatID: UUID, type: FormatType) -> URL
    public func metadataSidecar(bookID: UUID) -> URL      // .../metadata.json
    public func cover(bookID: UUID) -> URL                // .../cover.jpg
    public struct Caches: Sendable {
        public let root: URL
        public func thumbnail(bookID: UUID, size: ThumbnailSize) -> URL
    }
}
public enum ThumbnailSize: String, CaseIterable, Sendable { case grid /*300px*/, list /*90px*/ }
public enum ThumbnailPipeline {
    /// Writes cover.jpg into the book dir and both thumbnail sizes into caches. No-op if coverData nil.
    public static func process(coverData: Data?, bookDir: URL, bookID: UUID, caches: LibraryPaths.Caches) throws
}
public struct Sidecar: Codable, Equatable {   // RWPM-shaped metadata.json (spec "Disk layout")
    public struct FormatEntry: Codable, Equatable {
        public let formatID: UUID, formatType: FormatType, originalFileName: String,
                   byteSize: Int64, contentHash: String
    }
    public let bookID: UUID
    public let metadata: ExtractedMetadata
    public let formats: [FormatEntry]
    public let applySeq: Int64
    public static func write(_ sidecar: Sidecar, to url: URL) throws     // atomic write
    public static func read(from url: URL) throws -> Sidecar
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/IqraLibraryTests/ThumbnailPipelineTests.swift
import XCTest
@testable import IqraLibrary

final class ThumbnailPipelineTests: XCTestCase {
    func testWritesCoverAndTwoThumbnailSizes() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = LibraryPaths(root: tmp.appendingPathComponent("lib"))
        let caches = LibraryPaths.Caches(root: tmp.appendingPathComponent("caches"))
        let bookID = UUID()
        let bookDir = paths.bookDir(bookID)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)

        try ThumbnailPipeline.process(coverData: Fixtures.tinyJPEG(), bookDir: bookDir,
                                      bookID: bookID, caches: caches)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cover(bookID).path))
        for size in ThumbnailSize.allCases {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: caches.thumbnail(bookID: bookID, size: size).path), "missing \(size)")
        }
    }

    func testNilCoverIsNoOp() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let caches = LibraryPaths.Caches(root: tmp.appendingPathComponent("caches"))
        try ThumbnailPipeline.process(coverData: nil, bookDir: tmp, bookID: UUID(), caches: caches)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("cover.jpg").path))
    }
}
```

```swift
// Tests/IqraLibraryTests/SidecarTests.swift
import XCTest
import IqraCore
@testable import IqraLibrary

final class SidecarTests: XCTestCase {
    func testRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let sidecar = Sidecar(
            bookID: UUID(),
            metadata: ExtractedMetadata(title: "T", titleSort: "T", language: "en", publisher: nil,
                                        bookDescription: nil, contributors: [], identifiers: []),
            formats: [.init(formatID: UUID(), formatType: .epub, originalFileName: "t.epub",
                            byteSize: 9, contentHash: "h")],
            applySeq: 7)
        try Sidecar.write(sidecar, to: tmp)
        XCTAssertEqual(try Sidecar.read(from: tmp), sidecar)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ThumbnailPipelineTests && swift test --filter SidecarTests`
Expected: FAIL — missing members on `LibraryPaths`, `cannot find 'ThumbnailPipeline'` / `'Sidecar'`.

- [ ] **Step 3: Write the implementations**

```swift
// Sources/IqraLibrary/LibraryPaths.swift  (replaces Task 1 placeholder)
import Foundation
import IqraCore

/// All knowledge of the managed-library filesystem layout in one place (spec "Disk layout"):
/// <root>/Books/<bookUUID>/{<formatUUID>.<ext>, metadata.json, cover.jpg}, staging at Books/.staging.
public struct LibraryPaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public var booksDir: URL { root.appendingPathComponent("Books", isDirectory: true) }
    public var stagingDir: URL { booksDir.appendingPathComponent(".staging", isDirectory: true) }
    public func bookDir(_ bookID: UUID) -> URL {
        booksDir.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }
    public func stagingBookDir(_ bookID: UUID) -> URL {
        stagingDir.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }
    public func formatFile(bookID: UUID, formatID: UUID, type: FormatType) -> URL {
        bookDir(bookID).appendingPathComponent("\(formatID.uuidString).\(type.fileExtension)")
    }
    public func metadataSidecar(bookID: UUID) -> URL {
        bookDir(bookID).appendingPathComponent("metadata.json")
    }
    public func cover(bookID: UUID) -> URL {
        bookDir(bookID).appendingPathComponent("cover.jpg")
    }

    public struct Caches: Sendable {
        public let root: URL
        public init(root: URL) { self.root = root }
        public func thumbnail(bookID: UUID, size: ThumbnailSize) -> URL {
            root.appendingPathComponent("thumbnails", isDirectory: true)
                .appendingPathComponent("\(bookID.uuidString)-\(size.rawValue).jpg")
        }
    }
}

public enum ThumbnailSize: String, CaseIterable, Sendable {
    case grid, list
    var maxPixel: Int { self == .grid ? 300 : 90 }
}
```

```swift
// Sources/IqraLibrary/Import/ThumbnailPipeline.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ThumbnailPipeline {
    /// Eager thumbnails at import time, never at scroll time (spec).
    public static func process(coverData: Data?, bookDir: URL, bookID: UUID,
                               caches: LibraryPaths.Caches) throws {
        guard let coverData else { return }
        try coverData.write(to: bookDir.appendingPathComponent("cover.jpg"), options: .atomic)

        let thumbsDir = caches.root.appendingPathComponent("thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        guard let source = CGImageSourceCreateWithData(coverData as CFData, nil) else { return }
        for size in ThumbnailSize.allCases {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: size.maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { continue }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { continue }
            try (out as Data).write(to: caches.thumbnail(bookID: bookID, size: size), options: .atomic)
        }
    }
}
```

```swift
// Sources/IqraLibrary/Import/Sidecar.swift
import Foundation
import IqraCore

/// Per-book metadata.json: makes every book folder self-describing so the DB is a
/// rebuildable index and orphan folders can be adopted (spec "Disk layout & durability").
public struct Sidecar: Codable, Equatable {
    public struct FormatEntry: Codable, Equatable {
        public let formatID: UUID
        public let formatType: FormatType
        public let originalFileName: String
        public let byteSize: Int64
        public let contentHash: String
        public init(formatID: UUID, formatType: FormatType, originalFileName: String,
                    byteSize: Int64, contentHash: String) {
            self.formatID = formatID; self.formatType = formatType
            self.originalFileName = originalFileName; self.byteSize = byteSize
            self.contentHash = contentHash
        }
    }
    public let bookID: UUID
    public let metadata: ExtractedMetadata
    public let formats: [FormatEntry]
    public let applySeq: Int64

    public init(bookID: UUID, metadata: ExtractedMetadata, formats: [FormatEntry], applySeq: Int64) {
        self.bookID = bookID; self.metadata = metadata; self.formats = formats; self.applySeq = applySeq
    }

    public static func write(_ sidecar: Sidecar, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> Sidecar {
        try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter ThumbnailPipelineTests && swift test --filter SidecarTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/IqraLibrary Tests/IqraLibraryTests
git commit -m "feat: library paths, thumbnail pipeline, and metadata sidecar"
```

---

### Task 9: Crash-safe ImportPipeline with dedupe ladder

**Files:**
- Create: `Sources/IqraLibrary/Import/ImportPipeline.swift`
- Test: `Tests/IqraLibraryTests/ImportPipelineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 3–8 (`LibraryStore.insertBook`, `FormatSniffer.sniff`, `EPUBMetadataExtractor.extract`, `PDFMetadataExtractor.extract`, `ThumbnailPipeline.process`, `Sidecar`, `LibraryPaths`), CryptoKit (system).
- Produces:

```swift
public enum ImportResult: Equatable, Sendable {
    case imported(bookID: UUID)
    case attached(bookID: UUID, formatID: UUID)
    case hydrated(formatID: UUID)
    case skippedExactDuplicate(formatID: UUID)
    case quarantined(ImportRejection)
    case needsUserDecision(existingBookID: UUID)   // identifier match — never silent (spec)
}
public enum IdentifierResolution: Sendable { case ask, importAsNewBook, attach(toBook: UUID) }
public final class ImportPipeline {
    public init(store: LibraryStore, dbm: DatabaseManager, paths: LibraryPaths, caches: LibraryPaths.Caches)
    @discardableResult
    public func importFile(at url: URL, resolution: IdentifierResolution = .ask) throws -> ImportResult
    var failpoint: Failpoint?                       // internal test hook
    enum Failpoint { case afterStaging, afterRename }
    struct FailpointError: Error {}
}
public func sha256Hex(of url: URL) throws -> String
```

Pipeline order (spec "Import pipeline" + "Crash-safe import protocol"): import_item row (`importing`) → sniff → classify/extract → hash → dedupe ladder → stage (copy as `<formatUUID>.<ext>` + sidecar + cover, fsync) → atomic rename into `Books/<bookUUID>/` → thumbnails → **DB insert last** → import_item `done`. Every quarantine/failure updates the import_item row.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IqraLibraryTests/ImportPipelineTests.swift
import XCTest
import IqraCore
import GRDB
@testable import IqraLibrary

final class ImportPipelineTests: XCTestCase {
    var dir: URL!
    var dbm: DatabaseManager!
    var store: LibraryStore!
    var paths: LibraryPaths!
    var caches: LibraryPaths.Caches!
    var pipeline: ImportPipeline!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbm = try DatabaseManager.inMemory()
        store = LibraryStore(dbm: dbm)
        paths = LibraryPaths(root: dir.appendingPathComponent("lib"))
        caches = LibraryPaths.Caches(root: dir.appendingPathComponent("caches"))
        pipeline = ImportPipeline(store: store, dbm: dbm, paths: paths, caches: caches)
    }

    func importCount(status: String) throws -> Int {
        try dbm.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM import_item WHERE status = ?",
                             arguments: [status])!
        }
    }

    func testHappyPathEPUB() throws {
        let epub = try Fixtures.makeEPUB(title: "The Dispossessed", author: "Ursula K. Le Guin",
                                         isbn: "9780060512750", coverJPEG: Fixtures.tinyJPEG(), dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else {
            return XCTFail("expected imported")
        }
        // DB row exists with metadata
        let book = try XCTUnwrap(store.fetchBook(bookID))
        XCTAssertEqual(book.title, "The Dispossessed")
        // managed folder layout: <formatUUID>.epub + metadata.json + cover.jpg
        let format = try XCTUnwrap(store.fetchFormats(bookID: bookID).first)
        let formatURL = paths.formatFile(bookID: bookID, formatID: UUID(uuidString: format.id)!, type: .epub)
        XCTAssertTrue(FileManager.default.fileExists(atPath: formatURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.metadataSidecar(bookID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cover(bookID).path))
        // sidecar agrees with the DB
        let sidecar = try Sidecar.read(from: paths.metadataSidecar(bookID))
        XCTAssertEqual(sidecar.bookID, bookID)
        XCTAssertEqual(sidecar.formats.first?.contentHash, format.contentHash)
        // no staging leftovers; import_item done
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stagingBookDir(bookID).path))
        XCTAssertEqual(try importCount(status: "done"), 1)
    }

    func testHappyPathPDF() throws {
        let pdf = try Fixtures.makePDF(title: "Design Patterns", author: "Gamma", dir: dir)
        guard case .imported = try pipeline.importFile(at: pdf) else { return XCTFail() }
        XCTAssertEqual(try importCount(status: "done"), 1)
    }

    func testDRMEPUBIsQuarantined() throws {
        let epub = try Fixtures.makeEPUB(title: "Locked", author: "X", isbn: nil, encrypted: true, dir: dir)
        XCTAssertEqual(try pipeline.importFile(at: epub), .quarantined(.drmProtected))
        XCTAssertEqual(try importCount(status: "quarantined"), 1)
        XCTAssertNil(try dbm.writer.read { try BookRecord.fetchOne($0) }) // nothing imported
    }

    func testUnsupportedFormatIsQuarantinedInM1() throws {
        let junk = dir.appendingPathComponent("junk.xyz")
        try Data("not a book".utf8).write(to: junk)
        XCTAssertEqual(try pipeline.importFile(at: junk), .quarantined(.unsupportedFormat))
    }

    func testExactDuplicateIsSkipped() throws {
        let epub = try Fixtures.makeEPUB(title: "Dup", author: "A", isbn: nil, dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else { return XCTFail() }
        let format = try XCTUnwrap(store.fetchFormats(bookID: bookID).first)
        XCTAssertEqual(try pipeline.importFile(at: epub),
                       .skippedExactDuplicate(formatID: UUID(uuidString: format.id)!))
        XCTAssertEqual(try dbm.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM book")! }, 1)
    }

    func testHashMatchWithMissingBinaryHydrates() throws {
        let epub = try Fixtures.makeEPUB(title: "Hyd", author: "A", isbn: nil, dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else { return XCTFail() }
        let format = try XCTUnwrap(store.fetchFormats(bookID: bookID).first)
        let formatID = UUID(uuidString: format.id)!
        // simulate lost binary (e.g. synced record without local file)
        let fileURL = paths.formatFile(bookID: bookID, formatID: formatID, type: .epub)
        try FileManager.default.removeItem(at: fileURL)
        try dbm.writer.write { db in
            try db.execute(sql: "UPDATE format_local SET present = 0, missing = 1 WHERE formatId = ?",
                           arguments: [format.id])
        }
        XCTAssertEqual(try pipeline.importFile(at: epub), .hydrated(formatID: formatID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let present = try dbm.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT present FROM format_local WHERE formatId = ?",
                              arguments: [format.id])!
        }
        XCTAssertTrue(present)
    }

    func testIdentifierMatchAsksThenAttaches() throws {
        // same ISBN, different bytes (different title string → different hash)
        let first = try Fixtures.makeEPUB(title: "Edition One", author: "A", isbn: "9780060512750", dir: dir)
        let second = try Fixtures.makeEPUB(title: "Edition Two", author: "A", isbn: "9780060512750", dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: first) else { return XCTFail() }
        // default: never silent
        XCTAssertEqual(try pipeline.importFile(at: second), .needsUserDecision(existingBookID: bookID))
        XCTAssertEqual(try dbm.writer.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM book")! }, 1)
        // user chose the default action: attach as a format of the existing book
        guard case let .attached(attachedBookID, formatID) =
            try pipeline.importFile(at: second, resolution: .attach(toBook: bookID)) else {
            return XCTFail("expected attached")
        }
        XCTAssertEqual(attachedBookID, bookID)
        XCTAssertEqual(try store.fetchFormats(bookID: bookID).count, 2)
        let fileURL = paths.formatFile(bookID: bookID, formatID: formatID, type: .epub)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCrashAfterStagingLeavesNoDBRow() throws {
        let epub = try Fixtures.makeEPUB(title: "Crash1", author: "A", isbn: nil, dir: dir)
        pipeline.failpoint = .afterStaging
        XCTAssertThrowsError(try pipeline.importFile(at: epub))
        XCTAssertNil(try dbm.writer.read { try BookRecord.fetchOne($0) })
        // staging leftover exists for the sweep to clean
        let staged = try FileManager.default.contentsOfDirectory(atPath: paths.stagingDir.path)
        XCTAssertEqual(staged.count, 1)
    }

    func testCrashAfterRenameLeavesAdoptableOrphan() throws {
        let epub = try Fixtures.makeEPUB(title: "Crash2", author: "A", isbn: nil, dir: dir)
        pipeline.failpoint = .afterRename
        XCTAssertThrowsError(try pipeline.importFile(at: epub))
        XCTAssertNil(try dbm.writer.read { try BookRecord.fetchOne($0) })
        // a fully-formed book folder exists (self-describing via sidecar), no DB row
        let folders = try FileManager.default.contentsOfDirectory(atPath: paths.booksDir.path)
            .filter { $0 != ".staging" }
        XCTAssertEqual(folders.count, 1)
        let sidecarURL = paths.booksDir.appendingPathComponent(folders[0]).appendingPathComponent("metadata.json")
        XCTAssertNoThrow(try Sidecar.read(from: sidecarURL))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ImportPipelineTests`
Expected: FAIL — `cannot find 'ImportPipeline'`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/IqraLibrary/Import/ImportPipeline.swift
import Foundation
import CryptoKit
import GRDB
import IqraCore

public enum ImportResult: Equatable, Sendable {
    case imported(bookID: UUID)
    case attached(bookID: UUID, formatID: UUID)
    case hydrated(formatID: UUID)
    case skippedExactDuplicate(formatID: UUID)
    case quarantined(ImportRejection)
    case needsUserDecision(existingBookID: UUID)
}

public enum IdentifierResolution: Sendable {
    case ask, importAsNewBook, attach(toBook: UUID)
}

public func sha256Hex(of url: URL) throws -> String {
    let data = try Data(contentsOf: url) // M1: whole-file read; stream if profiling demands
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public final class ImportPipeline {
    let store: LibraryStore
    let dbm: DatabaseManager
    let paths: LibraryPaths
    let caches: LibraryPaths.Caches

    enum Failpoint { case afterStaging, afterRename }
    struct FailpointError: Error {}
    var failpoint: Failpoint?
    private func hit(_ point: Failpoint) throws {
        if failpoint == point { throw FailpointError() }
    }

    public init(store: LibraryStore, dbm: DatabaseManager, paths: LibraryPaths,
                caches: LibraryPaths.Caches) {
        self.store = store; self.dbm = dbm; self.paths = paths; self.caches = caches
    }

    @discardableResult
    public func importFile(at url: URL, resolution: IdentifierResolution = .ask) throws -> ImportResult {
        let itemID = UUID().uuidString
        try upsertImportItem(id: itemID, path: url.path, status: "importing", rejection: nil, bookId: nil)

        // 1. sniff — magic bytes, never extension
        guard case let .recognized(formatType) = try FormatSniffer.sniff(fileURL: url),
              formatType == .epub || formatType == .pdf else {
            // cbz/cbr/mobi arrive in M4/M5; everything unrecognized or not-yet-supported quarantines
            try upsertImportItem(id: itemID, path: url.path, status: "quarantined",
                                 rejection: .unsupportedFormat, bookId: nil)
            return .quarantined(.unsupportedFormat)
        }

        // 2–4. classify + extract metadata + cover (native, local-only)
        let extraction = formatType == .epub
            ? EPUBMetadataExtractor.extract(fileURL: url)
            : PDFMetadataExtractor.extract(fileURL: url)
        guard case let .extracted(metadata, coverData) = extraction else {
            guard case let .rejected(reason) = extraction else { fatalError("unreachable") }
            try upsertImportItem(id: itemID, path: url.path, status: "quarantined",
                                 rejection: reason, bookId: nil)
            return .quarantined(reason)
        }

        // 5. dedupe ladder
        let hash = try sha256Hex(of: url)
        switch try dedupe(hash: hash, identifiers: metadata.identifiers, resolution: resolution) {
        case let .skipExactDuplicate(formatID):
            try upsertImportItem(id: itemID, path: url.path, status: "done", rejection: nil, bookId: nil)
            return .skippedExactDuplicate(formatID: formatID)
        case let .hydrate(formatID):
            try hydrate(formatID: formatID, from: url, hash: hash, type: formatType)
            try upsertImportItem(id: itemID, path: url.path, status: "done", rejection: nil, bookId: nil)
            return .hydrated(formatID: formatID)
        case let .askIdentifierMatch(existingBookID):
            try upsertImportItem(id: itemID, path: url.path, status: "pending", rejection: nil, bookId: nil)
            return .needsUserDecision(existingBookID: existingBookID)
        case .newBook:
            break
        }

        if case let .attach(bookID) = resolution {
            let formatID = try attach(url: url, to: bookID, type: formatType,
                                      hash: hash, metadata: metadata)
            try upsertImportItem(id: itemID, path: url.path, status: "done",
                                 rejection: nil, bookId: bookID.uuidString)
            return .attached(bookID: bookID, formatID: formatID)
        }

        // 6. stage → atomic rename → DB row LAST (spec crash-safe protocol)
        let bookID = UUID(), formatID = UUID()
        let staging = paths.stagingBookDir(bookID)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedFile = staging.appendingPathComponent("\(formatID.uuidString).\(formatType.fileExtension)")
        try FileManager.default.copyItem(at: url, to: stagedFile)
        try fsync(stagedFile)
        let byteSize = (try FileManager.default.attributesOfItem(atPath: stagedFile.path)[.size] as? Int64) ?? 0
        let sidecar = Sidecar(
            bookID: bookID, metadata: metadata,
            formats: [.init(formatID: formatID, formatType: formatType,
                            originalFileName: url.lastPathComponent,
                            byteSize: byteSize, contentHash: hash)],
            applySeq: 0) // stamped properly on adoption/insert; sidecar seq updated post-insert in later milestones
        try Sidecar.write(sidecar, to: staging.appendingPathComponent("metadata.json"))
        if let coverData {
            try coverData.write(to: staging.appendingPathComponent("cover.jpg"), options: .atomic)
        }
        try hit(.afterStaging)

        let finalDir = paths.bookDir(bookID)
        try FileManager.default.moveItem(at: staging, to: finalDir) // atomic rename, same volume
        try hit(.afterRename)

        try ThumbnailPipeline.process(coverData: coverData, bookDir: finalDir,
                                      bookID: bookID, caches: caches)
        try store.insertBook(metadata: metadata, formatType: formatType,
                             originalFileName: url.lastPathComponent, byteSize: byteSize,
                             contentHash: hash, bookID: bookID, formatID: formatID)
        try upsertImportItem(id: itemID, path: url.path, status: "done",
                             rejection: nil, bookId: bookID.uuidString)
        return .imported(bookID: bookID)
    }

    // MARK: - ladder

    private func dedupe(hash: String, identifiers: [BookIdentifier],
                        resolution: IdentifierResolution) throws -> DedupeDecision {
        try dbm.writer.read { db in
            if let row = try Row.fetchOne(db, sql: """
                SELECT f.id, fl.present FROM format f
                JOIN format_local fl ON fl.formatId = f.id
                WHERE f.contentHash = ? AND f.deleted = 0
                """, arguments: [hash]) {
                let formatID = UUID(uuidString: row["id"])!
                return (row["present"] as Bool)
                    ? .skipExactDuplicate(formatID: formatID)
                    : .hydrate(formatID: formatID)
            }
            if case .ask = resolution {
                for ident in identifiers where ident.type != "uuid" {
                    if let bookId = try String.fetchOne(db, sql: """
                        SELECT i.bookId FROM identifier i JOIN book b ON b.id = i.bookId
                        WHERE i.type = ? AND i.value = ? AND b.deleted = 0
                        """, arguments: [ident.type, ident.value]) {
                        return .askIdentifierMatch(existingBookID: UUID(uuidString: bookId)!)
                    }
                }
            }
            return .newBook
        }
    }

    private func hydrate(formatID: UUID, from url: URL, hash: String, type: FormatType) throws {
        let (bookIdString, storedHash) = try dbm.writer.read { db -> (String, String) in
            let row = try Row.fetchOne(db, sql: "SELECT bookId, contentHash FROM format WHERE id = ?",
                                       arguments: [formatID.uuidString])!
            return (row["bookId"], row["contentHash"])
        }
        guard storedHash == hash else { throw FailpointError() } // defensive; caller matched on hash
        let bookID = UUID(uuidString: bookIdString)!
        let dest = paths.formatFile(bookID: bookID, formatID: formatID, type: type)
        try FileManager.default.createDirectory(at: paths.bookDir(bookID), withIntermediateDirectories: true)
        let tmp = dest.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: url, to: tmp)
        try fsync(tmp)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        try dbm.writer.write { db in
            try db.execute(sql: """
                UPDATE format_local SET present = 1, missing = 0, localVerifiedAt = ? WHERE formatId = ?
                """, arguments: [Date(), formatID.uuidString])
        }
    }

    private func attach(url: URL, to bookID: UUID, type: FormatType,
                        hash: String, metadata: ExtractedMetadata) throws -> UUID {
        let formatID = UUID()
        let dest = paths.formatFile(bookID: bookID, formatID: formatID, type: type)
        let tmp = dest.appendingPathExtension("partial")
        try FileManager.default.copyItem(at: url, to: tmp)
        try fsync(tmp)
        try FileManager.default.moveItem(at: tmp, to: dest)
        let byteSize = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        try dbm.writer.write { db in
            let seq = try dbm.nextApplySequence(db)
            try FormatRecord(id: formatID.uuidString, bookId: bookID.uuidString,
                             formatType: type.rawValue, originalFileName: url.lastPathComponent,
                             byteSize: byteSize, contentHash: hash, addedAt: Date(),
                             applySeq: seq, deleted: false).insert(db)
            try db.execute(sql: "INSERT INTO format_local (formatId, present, localVerifiedAt, missing) VALUES (?, 1, ?, 0)",
                           arguments: [formatID.uuidString, Date()])
        }
        // keep the sidecar self-describing
        let sidecarURL = paths.metadataSidecar(bookID)
        if var sidecar = try? Sidecar.read(from: sidecarURL) {
            sidecar = Sidecar(bookID: sidecar.bookID, metadata: sidecar.metadata,
                              formats: sidecar.formats + [.init(formatID: formatID, formatType: type,
                                                                originalFileName: url.lastPathComponent,
                                                                byteSize: byteSize, contentHash: hash)],
                              applySeq: sidecar.applySeq)
            try Sidecar.write(sidecar, to: sidecarURL)
        }
        return formatID
    }

    // MARK: - helpers

    private func fsync(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private func upsertImportItem(id: String, path: String, status: String,
                                  rejection: ImportRejection?, bookId: String?) throws {
        try dbm.writer.write { db in
            try db.execute(sql: """
                INSERT INTO import_item (id, sourceBookmark, sourceDisplayPath, status, rejection,
                                         message, attemptCount, createdAt, updatedAt, bookId)
                VALUES (?, NULL, ?, ?, ?, NULL, 1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET status = excluded.status,
                    rejection = excluded.rejection, updatedAt = excluded.updatedAt,
                    bookId = excluded.bookId
                """, arguments: [id, path, status, rejection?.rawValue, Date(), Date(), bookId])
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter ImportPipelineTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Run the full suite (regression gate)**

Run: `swift test`
Expected: PASS, all tasks so far.

- [ ] **Step 6: Commit**

```bash
git add Sources/IqraLibrary/Import Tests/IqraLibraryTests
git commit -m "feat: crash-safe import pipeline with dedupe ladder and quarantine"
```

---

### Task 10: Reconciliation sweep

**Files:**
- Create: `Sources/IqraLibrary/Import/ReconciliationSweep.swift`
- Test: `Tests/IqraLibraryTests/ReconciliationSweepTests.swift`

**Interfaces:**
- Consumes: `LibraryPaths`, `Sidecar`, `LibraryStore.insertBook`, `DatabaseManager` (Tasks 3–9).
- Produces:

```swift
public struct SweepReport: Equatable, Sendable {
    public var stagingDeleted: Int
    public var orphansAdopted: Int
    public var formatsMarkedMissing: Int
}
public enum ReconciliationSweep {
    /// Startup invariants (spec "Crash-safe import protocol"):
    /// staging dirs deleted; book folders without DB rows adopted from sidecars;
    /// DB formats whose file is gone marked missing in format_local.
    @discardableResult
    public static func run(paths: LibraryPaths, store: LibraryStore, dbm: DatabaseManager) throws -> SweepReport
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IqraLibraryTests/ReconciliationSweepTests.swift
import XCTest
import IqraCore
import GRDB
@testable import IqraLibrary

final class ReconciliationSweepTests: XCTestCase {
    var dir: URL!
    var dbm: DatabaseManager!
    var store: LibraryStore!
    var paths: LibraryPaths!
    var caches: LibraryPaths.Caches!
    var pipeline: ImportPipeline!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbm = try DatabaseManager.inMemory()
        store = LibraryStore(dbm: dbm)
        paths = LibraryPaths(root: dir.appendingPathComponent("lib"))
        caches = LibraryPaths.Caches(root: dir.appendingPathComponent("caches"))
        pipeline = ImportPipeline(store: store, dbm: dbm, paths: paths, caches: caches)
    }

    func testCleansStagingLeftovers() throws {
        let epub = try Fixtures.makeEPUB(title: "Crash1", author: "A", isbn: nil, dir: dir)
        pipeline.failpoint = .afterStaging
        XCTAssertThrowsError(try pipeline.importFile(at: epub))

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm)
        XCTAssertEqual(report.stagingDeleted, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.stagingDir.path).count, 0)
    }

    func testAdoptsOrphanFolderFromSidecar() throws {
        let epub = try Fixtures.makeEPUB(title: "Orphan Book", author: "A. Author",
                                         isbn: "9990000000001", dir: dir)
        pipeline.failpoint = .afterRename
        XCTAssertThrowsError(try pipeline.importFile(at: epub))
        XCTAssertNil(try dbm.writer.read { try BookRecord.fetchOne($0) })

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm)
        XCTAssertEqual(report.orphansAdopted, 1)
        let book = try XCTUnwrap(try dbm.writer.read { try BookRecord.fetchOne($0) })
        XCTAssertEqual(book.title, "Orphan Book")
        // adopted format is present locally (the file is in the folder)
        let format = try XCTUnwrap(store.fetchFormats(bookID: UUID(uuidString: book.id)!).first)
        let present = try dbm.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT present FROM format_local WHERE formatId = ?",
                              arguments: [format.id])!
        }
        XCTAssertTrue(present)
        // idempotent: second sweep adopts nothing
        XCTAssertEqual(try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm).orphansAdopted, 0)
    }

    func testMarksMissingFormats() throws {
        let epub = try Fixtures.makeEPUB(title: "Vanishing", author: "A", isbn: nil, dir: dir)
        guard case let .imported(bookID) = try pipeline.importFile(at: epub) else { return XCTFail() }
        let format = try XCTUnwrap(store.fetchFormats(bookID: bookID).first)
        try FileManager.default.removeItem(
            at: paths.formatFile(bookID: bookID, formatID: UUID(uuidString: format.id)!, type: .epub))

        let report = try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm)
        XCTAssertEqual(report.formatsMarkedMissing, 1)
        let row = try dbm.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT present, missing FROM format_local WHERE formatId = ?",
                             arguments: [format.id])!
        }
        XCTAssertEqual(row["present"] as Bool, false)
        XCTAssertEqual(row["missing"] as Bool, true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReconciliationSweepTests`
Expected: FAIL — `cannot find 'ReconciliationSweep'`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/IqraLibrary/Import/ReconciliationSweep.swift
import Foundation
import GRDB
import IqraCore

public struct SweepReport: Equatable, Sendable {
    public var stagingDeleted = 0
    public var orphansAdopted = 0
    public var formatsMarkedMissing = 0
    public init() {}
}

public enum ReconciliationSweep {
    @discardableResult
    public static func run(paths: LibraryPaths, store: LibraryStore,
                           dbm: DatabaseManager) throws -> SweepReport {
        var report = SweepReport()
        let fm = FileManager.default

        // 1. staging leftovers: import never completed; source file is still at origin. Delete.
        if let staged = try? fm.contentsOfDirectory(at: paths.stagingDir, includingPropertiesForKeys: nil) {
            for url in staged {
                try fm.removeItem(at: url)
                report.stagingDeleted += 1
            }
        }

        // 2. orphan book folders (crash after rename, before DB row): adopt from sidecar.
        let knownBookIDs: Set<String> = try dbm.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM book"))
        }
        if let folders = try? fm.contentsOfDirectory(at: paths.booksDir, includingPropertiesForKeys: nil) {
            for folder in folders where folder.lastPathComponent != ".staging" {
                let name = folder.lastPathComponent
                guard !knownBookIDs.contains(name) else { continue }
                guard let sidecar = try? Sidecar.read(from: folder.appendingPathComponent("metadata.json")),
                      let entry = sidecar.formats.first else { continue } // undescribed folder: leave for the user
                try store.insertBook(metadata: sidecar.metadata, formatType: entry.formatType,
                                     originalFileName: entry.originalFileName,
                                     byteSize: entry.byteSize, contentHash: entry.contentHash,
                                     bookID: sidecar.bookID, formatID: entry.formatID)
                report.orphansAdopted += 1
            }
        }

        // 3. DB rows whose binary vanished: mark missing, surface in UI (never delete data).
        let rows: [(formatId: String, bookId: String, type: String)] = try dbm.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id AS formatId, f.bookId AS bookId, f.formatType AS type
                FROM format f JOIN format_local fl ON fl.formatId = f.id
                WHERE fl.present = 1 AND f.deleted = 0
                """).map { ($0["formatId"], $0["bookId"], $0["type"]) }
        }
        for row in rows {
            guard let bookID = UUID(uuidString: row.bookId),
                  let formatID = UUID(uuidString: row.formatId),
                  let type = FormatType(rawValue: row.type) else { continue }
            let file = paths.formatFile(bookID: bookID, formatID: formatID, type: type)
            if !fm.fileExists(atPath: file.path) {
                try dbm.writer.write { db in
                    try db.execute(sql: """
                        UPDATE format_local SET present = 0, missing = 1 WHERE formatId = ?
                        """, arguments: [row.formatId])
                }
                report.formatsMarkedMissing += 1
            }
        }
        return report
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter ReconciliationSweepTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/IqraLibrary/Import Tests/IqraLibraryTests
git commit -m "feat: startup reconciliation sweep (staging, orphan adoption, missing binaries)"
```

---

### Task 11: LibraryStore queries — list, FTS search, observation, quarantine

**Files:**
- Modify: `Sources/IqraLibrary/Database/LibraryStore.swift`
- Test: `Tests/IqraLibraryTests/LibraryStoreTests.swift`

**Interfaces:**
- Consumes: Tasks 3–4.
- Produces (consumed by the app in Task 12):

```swift
public struct BookListItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let authors: String     // display string, ordinal order
    public let addedAt: Date
}
public enum BookSort: String, CaseIterable, Sendable { case titleSort, recentlyAdded, authorSort }
extension LibraryStore {
    public func listBooks(sort: BookSort) throws -> [BookListItem]
    public func searchBooks(_ query: String) throws -> [BookListItem]   // FTS5 prefix match
    public func quarantinedItems() throws -> [ImportItemRecord]
    /// GRDB ValueObservation of the book list; the app observes this for reactive UI.
    public func observeBooks(sort: BookSort) -> ValueObservation<ValueReducers.Fetch<[BookListItem]>>
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Tests/IqraLibraryTests/LibraryStoreTests.swift
import XCTest
import IqraCore
import GRDB
@testable import IqraLibrary

final class LibraryStoreTests: XCTestCase {
    var store: LibraryStore!
    var dbm: DatabaseManager!

    override func setUpWithError() throws {
        dbm = try DatabaseManager.inMemory()
        store = LibraryStore(dbm: dbm)
    }

    func insert(_ title: String, author: String, description: String = "") throws {
        let meta = ExtractedMetadata(
            title: title, titleSort: makeTitleSort(title, language: "en"), language: "en",
            publisher: nil, bookDescription: description,
            contributors: [Contributor(name: author,
                                       sortName: EPUBMetadataExtractor.makeAuthorSort(author),
                                       role: .author)],
            identifiers: [])
        try store.insertBook(metadata: meta, formatType: .epub, originalFileName: "\(title).epub",
                             byteSize: 1, contentHash: UUID().uuidString,
                             bookID: UUID(), formatID: UUID())
    }

    func testListSortsByTitleSort() throws {
        try insert("The Zebra Book", author: "Z Author")
        try insert("Apples", author: "A Author")
        let titles = try store.listBooks(sort: .titleSort).map(\.title)
        XCTAssertEqual(titles, ["Apples", "The Zebra Book"]) // "Zebra Book, The" sorts after "Apples"
    }

    func testFTSSearchMatchesTitleAuthorDescription() throws {
        try insert("The Dispossessed", author: "Ursula K. Le Guin", description: "An ambiguous utopia")
        try insert("Dune", author: "Frank Herbert", description: "Spice")
        XCTAssertEqual(try store.searchBooks("disposs").map(\.title), ["The Dispossessed"]) // prefix
        XCTAssertEqual(try store.searchBooks("guin").map(\.title), ["The Dispossessed"])    // author
        XCTAssertEqual(try store.searchBooks("utopia").map(\.title), ["The Dispossessed"])  // description
        XCTAssertEqual(try store.searchBooks("zzzz").count, 0)
    }

    func testObservationFiresOnInsert() throws {
        let expectation = expectation(description: "observed")
        expectation.expectedFulfillmentCount = 2 // initial + after insert
        var seen: [[BookListItem]] = []
        let cancellable = store.observeBooks(sort: .recentlyAdded).start(
            in: dbm.writer,
            onError: { XCTFail("\($0)") },
            onChange: { items in seen.append(items); expectation.fulfill() })
        try insert("New Arrival", author: "N. A.")
        wait(for: [expectation], timeout: 5)
        cancellable.cancel()
        XCTAssertEqual(seen.last?.map(\.title), ["New Arrival"])
    }

    func testQuarantinedItems() throws {
        try dbm.writer.write { db in
            try ImportItemRecord(id: UUID().uuidString, sourceBookmark: nil,
                                 sourceDisplayPath: "/x/locked.epub", status: "quarantined",
                                 rejection: "drmProtected", message: nil, attemptCount: 1,
                                 createdAt: Date(), updatedAt: Date(), bookId: nil).insert(db)
        }
        let items = try store.quarantinedItems()
        XCTAssertEqual(items.map(\.rejection), ["drmProtected"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LibraryStoreTests`
Expected: FAIL — missing `listBooks`/`BookListItem`.

- [ ] **Step 3: Write the implementation**

Append to `Sources/IqraLibrary/Database/LibraryStore.swift`:

```swift
public struct BookListItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let authors: String
    public let addedAt: Date
}

public enum BookSort: String, CaseIterable, Sendable {
    case titleSort, recentlyAdded, authorSort

    var sql: String {
        switch self {
        case .titleSort: "b.titleSort COLLATE NOCASE ASC"
        case .recentlyAdded: "b.addedAt DESC"
        case .authorSort: "authors COLLATE NOCASE ASC, b.titleSort COLLATE NOCASE ASC"
        }
    }
}

extension LibraryStore {
    private static let listSQL = """
        SELECT b.id AS id, b.title AS title, b.addedAt AS addedAt,
               COALESCE(group_concat(c.name, ', '), '') AS authors
        FROM book b
        LEFT JOIN book_contributor bc ON bc.bookId = b.id AND bc.role = 'author'
        LEFT JOIN contributor c ON c.id = bc.contributorId
        WHERE b.deleted = 0 %WHERE%
        GROUP BY b.id
        """

    private static func mapItems(_ rows: [Row]) -> [BookListItem] {
        rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            return BookListItem(id: id, title: row["title"], authors: row["authors"],
                                addedAt: row["addedAt"])
        }
    }

    public func listBooks(sort: BookSort) throws -> [BookListItem] {
        try dbm.writer.read { db in
            let sql = Self.listSQL.replacingOccurrences(of: "%WHERE%", with: "")
                + " ORDER BY \(sort.sql)"
            return Self.mapItems(try Row.fetchAll(db, sql: sql))
        }
    }

    public func searchBooks(_ query: String) throws -> [BookListItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try listBooks(sort: .titleSort) }
        // quote each token and add prefix-match star; quoting neutralizes FTS operators in user input
        let match = trimmed.split(separator: " ")
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
            .joined(separator: " ")
        return try dbm.writer.read { db in
            let sql = Self.listSQL.replacingOccurrences(
                of: "%WHERE%",
                with: "AND b.id IN (SELECT bookId FROM fts.book_fts WHERE book_fts MATCH ?)")
                + " ORDER BY b.titleSort COLLATE NOCASE ASC"
            return Self.mapItems(try Row.fetchAll(db, sql: sql, arguments: [match]))
        }
    }

    public func quarantinedItems() throws -> [ImportItemRecord] {
        try dbm.writer.read { db in
            try ImportItemRecord
                .filter(Column("status") == "quarantined" || Column("status") == "failed")
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    public func observeBooks(sort: BookSort) -> ValueObservation<ValueReducers.Fetch<[BookListItem]>> {
        ValueObservation.tracking { db in
            let sql = Self.listSQL.replacingOccurrences(of: "%WHERE%", with: "")
                + " ORDER BY \(sort.sql)"
            return Self.mapItems(try Row.fetchAll(db, sql: sql))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter LibraryStoreTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/IqraLibrary/Database Tests/IqraLibraryTests
git commit -m "feat: library queries — sorted list, FTS search, observation, quarantine"
```

---

### Task 12: App shell — XcodeGen project + SwiftUI library UI

**Files:**
- Create: `App/project.yml`
- Create: `App/Sources/IqraApp.swift`
- Create: `App/Sources/LibraryViewModel.swift`
- Create: `App/Sources/LibraryView.swift`
- Modify: `.gitignore` (add `App/iqra.xcodeproj`)
- Modify: `CLAUDE.md` (fill in the Commands section)

**Interfaces:**
- Consumes: `LibraryStore` queries + `observeBooks` (Task 11), `ImportPipeline` (Task 9), `ReconciliationSweep` (Task 10), `LibraryPaths` (Task 8), `DatabaseManager` (Task 3).
- Produces: a runnable `iqra` app (macOS + iOS) with grid, search, import button, quarantine sheet. No XCUITest gate — all logic already unit-tested in the packages.

- [ ] **Step 1: Install XcodeGen (if absent) and write the manifest**

Run: `command -v xcodegen || brew install xcodegen`

```yaml
# App/project.yml
name: iqra
options:
  bundleIdPrefix: pro.tilli
  deploymentTarget:
    iOS: "17.0"
    macOS: "14.0"
packages:
  Iqra:
    path: ..
targets:
  iqra:
    type: application
    supportedDestinations: [iOS, macOS]
    sources: [Sources]
    dependencies:
      - package: Iqra
        product: IqraLibrary
      - package: Iqra
        product: IqraCore
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: iqra
        ENABLE_HARDENED_RUNTIME: YES
        ENABLE_APP_SANDBOX: YES
        INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace: NO
      configs:
        Debug:
          CODE_SIGN_IDENTITY: "-"
```

- [ ] **Step 2: Write the app entry + view model**

```swift
// App/Sources/IqraApp.swift
import SwiftUI
import IqraLibrary

@main
struct IqraApp: App {
    @State private var model = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model)
                .task { await model.start() }
        }
    }
}
```

```swift
// App/Sources/LibraryViewModel.swift
import Foundation
import Observation
import IqraCore
import IqraLibrary

@Observable @MainActor
final class LibraryViewModel {
    private(set) var books: [BookListItem] = []
    private(set) var quarantined: [ImportItemRecord] = []
    var searchText = "" { didSet { Task { await refreshSearch() } } }
    var sort: BookSort = .titleSort { didSet { Task { await restartObservation() } } }
    var lastError: String?
    var pendingIdentifierMatch: (sourceURL: URL, existingBookID: UUID)?

    private var store: LibraryStore!
    private var pipeline: ImportPipeline!
    private var paths: LibraryPaths!
    private var caches: LibraryPaths.Caches!
    private var observationTask: Task<Void, Never>?

    func start() async {
        do {
            let fm = FileManager.default
            let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
                .appendingPathComponent("iqra", isDirectory: true)
            let cachesRoot = try fm.url(for: .cachesDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true)
                .appendingPathComponent("iqra", isDirectory: true)
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            paths = LibraryPaths(root: appSupport)
            caches = LibraryPaths.Caches(root: cachesRoot)
            try fm.createDirectory(at: paths.booksDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.stagingDir, withIntermediateDirectories: true)

            let dbm = try DatabaseManager(
                catalogueURL: appSupport.appendingPathComponent("catalogue.sqlite"),
                ftsURL: appSupport.appendingPathComponent("fts.sqlite"))
            store = LibraryStore(dbm: dbm)
            pipeline = ImportPipeline(store: store, dbm: dbm, paths: paths, caches: caches)
            try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm)
            quarantined = try store.quarantinedItems()
            await restartObservation()
        } catch {
            lastError = "\(error)"
        }
    }

    func coverURL(for bookID: UUID) -> URL? {
        guard let caches else { return nil }
        let url = caches.thumbnail(bookID: bookID, size: .grid)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func importFiles(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try pipeline.importFile(at: url)
                if case let .needsUserDecision(existingBookID) = result {
                    pendingIdentifierMatch = (url, existingBookID)
                }
            } catch {
                lastError = "Import failed for \(url.lastPathComponent): \(error)"
            }
        }
        quarantined = (try? store.quarantinedItems()) ?? quarantined
    }

    func resolveIdentifierMatch(attach: Bool) async {
        guard let pending = pendingIdentifierMatch else { return }
        pendingIdentifierMatch = nil
        let scoped = pending.sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { pending.sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            _ = try pipeline.importFile(
                at: pending.sourceURL,
                resolution: attach ? .attach(toBook: pending.existingBookID) : .importAsNewBook)
        } catch {
            lastError = "\(error)"
        }
    }

    private func refreshSearch() async {
        guard let store else { return }
        if searchText.isEmpty {
            await restartObservation()
        } else {
            observationTask?.cancel()
            books = (try? store.searchBooks(searchText)) ?? []
        }
    }

    private func restartObservation() async {
        guard let store else { return }
        observationTask?.cancel()
        let observation = store.observeBooks(sort: sort)
        observationTask = Task { [weak self] in
            do {
                for try await items in observation.values(in: store.dbm.writer) {
                    guard let self, self.searchText.isEmpty else { return }
                    self.books = items
                }
            } catch { /* task cancelled or db closed */ }
        }
    }
}
```

Note: `store.dbm` is `let dbm` in `LibraryStore` (Task 4) — change its access level from implicit internal to `public let dbm: DatabaseManager` if the compiler complains across module boundary; that single-line tweak is expected here.

- [ ] **Step 3: Write the view**

```swift
// App/Sources/LibraryView.swift
import SwiftUI
import UniformTypeIdentifiers
import IqraLibrary

struct LibraryView: View {
    @Bindable var model: LibraryViewModel
    @State private var showImporter = false
    @State private var showQuarantine = false

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]
    private static let bookTypes: [UTType] = [
        UTType("org.idpf.epub-container") ?? .epub, .pdf,
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(model.books) { book in
                        VStack(alignment: .leading, spacing: 6) {
                            CoverView(url: model.coverURL(for: book.id))
                            Text(book.title).font(.callout).lineLimit(2)
                            Text(book.authors).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Library")
            .searchable(text: $model.searchText, prompt: "Title, author, description")
            .toolbar {
                ToolbarItem {
                    Picker("Sort", selection: $model.sort) {
                        Text("Title").tag(BookSort.titleSort)
                        Text("Recent").tag(BookSort.recentlyAdded)
                        Text("Author").tag(BookSort.authorSort)
                    }
                }
                ToolbarItem {
                    Button("Quarantine", systemImage: "exclamationmark.triangle") {
                        showQuarantine = true
                    }
                    .disabled(model.quarantined.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Import", systemImage: "plus") { showImporter = true }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.bookTypes,
                          allowsMultipleSelection: true) { result in
                if case let .success(urls) = result {
                    Task { await model.importFiles(urls) }
                }
            }
            .sheet(isPresented: $showQuarantine) {
                QuarantineList(items: model.quarantined)
            }
            .alert("Same identifier as an existing book",
                   isPresented: .init(get: { model.pendingIdentifierMatch != nil },
                                      set: { if !$0 { model.pendingIdentifierMatch = nil } })) {
                Button("Attach to existing book") { Task { await model.resolveIdentifierMatch(attach: true) } }
                Button("Import as new book") { Task { await model.resolveIdentifierMatch(attach: false) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This file shares an identifier (e.g. ISBN) with a book already in your library.")
            }
            .alert("Error", isPresented: .init(get: { model.lastError != nil },
                                               set: { if !$0 { model.lastError = nil } })) {
                Button("OK") { model.lastError = nil }
            } message: { Text(model.lastError ?? "") }
        }
    }
}

private struct CoverView: View {
    let url: URL?
    var body: some View {
        Group {
            if let url, let data = try? Data(contentsOf: url) {
                #if os(macOS)
                if let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else { placeholder }
                #else
                if let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else { placeholder }
                #endif
            } else { placeholder }
        }
        .frame(width: 140, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 2)
    }
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary))
    }
}

private struct QuarantineList: View {
    let items: [ImportItemRecord]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(items) { item in
                VStack(alignment: .leading) {
                    Text((item.sourceDisplayPath as NSString).lastPathComponent).font(.body)
                    Text(item.rejection ?? item.status).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle("Not Imported")
            .toolbar { ToolbarItem { Button("Done") { dismiss() } } }
        }
    }
}
```

- [ ] **Step 4: Generate and build**

Run:
```bash
cd App && xcodegen generate && cd ..
xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build
```
Expected: `BUILD SUCCEEDED`. Fix any minor API drift (e.g. the `dbm` access level noted in Step 2) — but structural changes go back through plan review.

- [ ] **Step 5: Manual smoke test (macOS)**

Run: `open App/iqra.xcodeproj` → Run the `iqra` scheme (My Mac). Verify:
1. Empty grid appears.
2. Import an EPUB and a PDF via the + button → covers/titles appear in the grid.
3. Search finds by author prefix.
4. Import the same EPUB again → no duplicate row appears.
5. Quit and relaunch → library persists.

- [ ] **Step 6: Update .gitignore and CLAUDE.md**

Append to `.gitignore`:
```
App/iqra.xcodeproj
.build/
```

Replace the `## Commands` section of `CLAUDE.md` with:
```markdown
## Commands

- `swift test` — run all package tests (IqraCore, IqraLibrary); this is the primary gate
- `swift test --filter <TestClassName>` — run one test class
- `cd App && xcodegen generate` — regenerate the Xcode project (project.yml is the source of truth; iqra.xcodeproj is gitignored)
- `xcodebuild -project App/iqra.xcodeproj -scheme iqra -destination 'platform=macOS' build` — build the app
```

- [ ] **Step 7: Commit**

```bash
git add App .gitignore CLAUDE.md
git commit -m "feat: SwiftUI app shell with library grid, import, search, and quarantine"
```

---

## Plan Self-Review Notes

- **Spec coverage (M1 scope):** schema v1 incl. future-milestone tables ✔; crash-safe import protocol ✔ (Task 9 + failpoint tests); dedupe ladder incl. hydrate + identifier prompt ✔; sidecars ✔ (userdata.json deliberately deferred to M3 with annotations — noted in spec as annotation-payload); reconciliation sweep ✔; FTS metadata search ✔ (content FTS deferred per spec stage 7 to a persisted queue — M1 indexes metadata only; the `content_fts` table intentionally does not exist yet and is NOT in migration v1); thumbnails eager at import ✔; quarantine UI ✔; library UI browse/search/sort ✔. Collections UI is spec'd for M1 as "browse/search/collections" — collections **UI** is deferred to M6 where Reading Now ships; the schema exists now. Flag this consciously: M1 delivers browse/search; collections tables are ready.
- **Deviation from spec, recorded:** spec says "three local Swift packages"; this plan uses one package with per-module targets (same boundary enforcement, less manifest overhead). IqraReader target arrives in M2.
- **Type consistency check:** `ExtractionResult` produced in Task 6, consumed in Tasks 7/9 ✔; `Sidecar.FormatEntry` field names match Task 9/10 usage ✔; `LibraryStore.insertBook` signature identical in Tasks 4/9/10 ✔; `ThumbnailSize.grid` used by Task 12 `coverURL` ✔.
- **Known risk points for the implementer:** ZIPFoundation `Archive(url:accessMode:)` is a throwing init in ≥0.9.16 (plan assumes it); GRDB 7 `ValueObservation.values(in:)` async sequence exists on `DatabaseWriter`; if minor API drift occurs, adapt locally and note it — structural changes go back through plan review.

## Execution

Plan complete. Execute with superpowers:subagent-driven-development (fresh subagent per task, review between tasks) or superpowers:executing-plans (inline with checkpoints).
