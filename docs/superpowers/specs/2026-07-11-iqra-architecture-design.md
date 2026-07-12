# iqra — Universal Apple-Platform Ebook Reader: Architecture Design

Status: validated. Both halves of this design were adversarially reviewed
(transcripts: `.lil-bro/20260711-211500-reader-design.md`, 11 findings, 10
folded in; `.lil-bro/20260711-215500-reader-design-part2.md`, 13 findings,
all folded in). Review IDs cited inline as *(R1-Fn)* / *(R2-Fn)*.

## Product intent

A native universal macOS/iOS/iPadOS ebook reader + library app with rough
feature parity with Apple Books: library shelves and collections, reading
position and progress UI, themes/typography, TOC, in-book search,
highlights and notes, bookmarks, PDF support. Audiobooks and any store are
out of scope. Differentiators worth exceeding Books on (both cheap):
annotation export and built-in text-to-speech.

## Locked decisions (with rationale)

1. **Native Swift/SwiftUI multiplatform** app shell (no cross-platform
   framework). Best path to Books-level platform fidelity.
2. **Formats:** EPUB, PDF, CBZ/CBR, MOBI/AZW3 — **DRM-free files only**.
   The import pipeline classifies and quarantines DRM-protected files
   (Kindle EXTH DRM flags, EPUB `encryption.xml` beyond font obfuscation)
   and unsupported variants (e.g. KFX) with explicit user-facing states —
   never a mysterious failure at open time. *(R1-F6)*
3. **EPUB engine: foliate-js inside WKWebView on BOTH platforms.**
   Readium swift-toolkit is verified iOS/iPadOS-only
   (`platforms: [.iOS("15.0")]`); no native Swift macOS EPUB navigator
   exists. foliate-js (MIT) is proven shippable on iOS+macOS App Stores
   (Anx Reader, Readest) and gives one pagination/anchoring codebase.
4. **Persistence: GRDB (SQLite, WAL) with CKSyncEngine later.** Records
   shaped CloudKit-compatible from day one. Rejected SwiftData+CloudKit
   and NSPersistentCloudKitContainer: no FTS5, no unique constraints, and
   opaque last-writer-wins conflicts — the wrong model for reading state.
5. **Managed copy-on-import library folder** (calibre/Apple Books model),
   not reference-in-place (Kavita/Komga-style scanners were the complexity
   sink in every project that chose them, and in-place fights the macOS
   sandbox).

## Identity, versioning & reading-state model (sync-critical, local-first)

- **Content identity, not just record identity.** Every format file
  carries a SHA-256 content hash; every book carries an open identifiers
  bag (ISBN, ASIN, …). UUIDs are record identity only. Sync merge rule:
  same content hash → same logical format record (deterministic winner by
  lowest UUID, annotations re-parented); identifier or normalized
  title+author match → merge candidate surfaced to the user. *(R1-F2)*
- **Three clocks, three jobs — never interchanged.** *(R1-F11, R2-F13)*
  (a) A **per-install monotonic counter** orders pre-sync writes within
  one device; never compared across installs. (b) **CKRecord change tags**
  detect causal divergence at sync time. (c) A **catalogue-local apply
  sequence** — incremented whenever the local DB accepts any change
  (local edit, remote sync application, restore merge) and stamped on the
  affected record — is the only clock used to merge restore artifacts
  (live DB, sidecars, snapshots), which is safe because all three come
  from the same catalogue. Wall-clock and server time are advisory
  display text only.
- **Reading state = two fields, keyed per (book, format).** *(R1-F1, F3)*
  `currentLocator` and a durable `candidates` list — each entry is the
  same structure `{ locator, deviceId, deviceName, localCounter,
  advisoryTime }` so conflict prompts attribute correctly *(R2-F9)* —
  plus `highWaterMark`: furthest-ever progress, merged by max, used only
  to phrase prompts and drive "finished" heuristics. Device identity is a
  stable per-install keychain UUID; device *name* is display text.
  Positions are never shared across formats or editions;
  `totalProgression` fractions are display/fallback only. Cross-edition
  position mapping is a non-goal.
- **Conflict resolution is causal, never temporal.** *(R1-F11)* Writes
  carrying a matching change tag fast-forward silently (the common case).
  Divergent writes are never auto-resolved: both candidates persist
  durably on the record, and the next book-open prompts Books-style
  ("You were at 82% on iPhone — go there?"); the choice becomes a new
  fast-forward write and clears the candidates.
- **Deletions are permanent tombstones.** *(R2-F7, F12)* `deleted` is
  monotonic — never subject to field-LWW, wins over any concurrent edit.
  Tombstones are never garbage-collected (tens of bytes each; a timer GC
  would let long-offline devices resurrect deletions). The trash view's
  N-day window is presentation only.

## System overview

A thin SwiftUI multiplatform app target (iOS 16+/iPadOS 16+/macOS 13+,
floors to be confirmed during planning) over three local Swift packages:

- **IqraCore** — shared value types: `Book`, `Format`, `Locator`,
  `Annotation`, `ReadingState`, the navigator protocols. No dependencies.
- **IqraLibrary** — the catalogue: GRDB database, import pipeline, FTS
  index, cover/thumbnail cache, managed library folder. **Owns native
  Swift metadata extractors for every container** — EPUB (OPF via XML),
  PDF (PDFKit info dict), CBZ/CBR (ComicInfo.xml), MOBI/AZW3 (compact
  EXTH-header parser for metadata + cover). The catalogue never depends
  on the reader or any JS engine; importing 500 AZW3 files yields full
  metadata, covers, and metadata search with no web view involved.
  *(R1-F5)*
- **IqraReader** — the reading engines: an EPUB/MOBI navigator
  (WKWebView + foliate-js), a PDF navigator (PDFKit), and a comics
  navigator (native image pager).

**Navigator abstraction is protocol composition, not one flat protocol**
*(R1-F8, mirroring Readium's split)*: a base `Navigator` (open/close,
go-to-locator, relocate events, TOC) plus capability protocols —
`TextSelectable` (EPUB/MOBI, PDF), `RangeAnnotatable` (EPUB/MOBI, PDF),
`Searchable`, `PageThumbnails` (PDF, comics). The UI drives features by
conformance checks, so it can never offer text highlighting on a CBZ page
image.

## The reflowable-text engine (EPUB, MOBI/KF8)

(FB2 comes free with foliate-js but is not a committed format.)

foliate-js inside WKWebView on both platforms — the same WebKit either
way, so one pagination and annotation-anchoring codebase.

- **Resource serving:** a `WKURLSchemeHandler` serves book resources
  (unzipped on demand via ZIPFoundation) under a custom scheme with a
  **unique host per book** for origin isolation. No localhost server —
  both Readium toolkits retired theirs (killed under memory pressure,
  leaks content across apps).
- **Security:** every book is treated as hostile. Strict CSP injected
  (`script-src` limited to our runtime), `WKContentRuleList` blocking all
  remote loads, publisher scripts stripped/unexecuted, WKWebView's
  content-process sandbox as the real boundary.
- **Swift↔JS bridge:** `WKUserScript` injects the foliate-js runtime at
  document start; `WKScriptMessageHandler` is the ONLY channel back to
  Swift (relocate events, selection info, annotation taps) — Thorium's
  preload-script pattern.
- **Pagination:** foliate-js's CSS multi-column paginator with
  bisection-based visible-range detection. Universally documented as the
  fragile spot; mitigations adopted: bounded preload (±1 spine item —
  WKWebView memory limits on iOS make more risky), and we never hand-roll
  layout.
- **Locator model (the load-bearing decision):** every stored
  position/annotation is a composite record:
  `{ spineHref, cfi, textContext (before/highlight/after),
  progressionInChapter, totalProgression }`. **Point CFI for reading
  positions; range CFI for annotations** (EPUB CFI ranges are spec'd and
  foliate-js parses/emits them; selections cannot span spine items since
  each spine item is its own document). CFI is the precise coordinate;
  text context enables fuzzy re-anchoring when CFI breaks; progression
  fractions are display-only. This is Readium's Locator design;
  annotation anchoring is the classic reader-app graveyard — hence
  redundancy. *(R1-F4)*
- **User settings:** Readium-CSS-style injection — CSS custom properties
  with USER > PUBLISHER > DEFAULT precedence and a "publisher styles"
  toggle, not DOM rewriting.
- **Annotations rendering:** foliate-js's SVG overlayer (drawn from
  `Range.getClientRects()`, redrawn on reflow) — overlays don't mutate
  the book DOM, so they can't corrupt anchors.
- **Process-kill recovery contract** *(R1-F10)*: the DB, not the web
  view, is the source of truth — every relocate/annotation event commits
  before acknowledgment. On `webViewWebContentProcessDidTerminate` the
  navigator rebuilds the web view and restores `(theme, settings,
  lastCommittedLocator)`; in-flight selection is acknowledged lost.
- **MOBI/AZW3:** rendered DIRECTLY — foliate-js parses MOBI/KF8 natively,
  so no convert-on-import pipeline. Catalogue metadata comes from
  IqraLibrary's native EXTH parser; MOBI *body text* for FTS is extracted
  lazily (on first open via the reader engine, or a later Swift KF8 text
  extractor). Conversion stays a possible later feature, not
  architecture.

## The other engines

- **PDF:** PDFKit — same API on both platforms — gives display modes
  (incl. two-page spread), thumbnails/scrubber, search, and outline TOC
  nearly free. Reading position = page index + `totalProgression`.
  **Highlight anchors are NOT page indexes**: a PDF annotation anchor is
  `{ pageIndex, quadPoints (normalized page coordinates), textQuote }`
  stored in the DB and rendered as PDFKit overlay annotations at load —
  never written into the PDF file. *(R1-F7)*
- **Comics (CBZ/CBR):** native paged image viewer. Archives are
  **extracted once to an evictable cache** at import or first open —
  solid RAR makes random access sequential-decompression-bound, and CBZ
  gets the same treatment for pager uniformity. Unsupported archive
  variants route to quarantine. Position = page index. CBR needs a RAR
  dependency (flagged for planning). *(R1-F9)*

# Part 2 — Catalogue, Import, Sync, App Structure, Build Order

## Catalogue schema (GRDB / SQLite, WAL mode)

The calibre model adapted for sync: a logical **Book** owns N physical
**Format** files. Every synced record carries: UUID, the catalogue-local
apply sequence (restore clock), and where mutable, a tombstone flag.

- `book` — UUID id, title + stored `titleSort` (locale-aware article
  stripping, computed once — never collate in queries), description,
  publisher, pubDate, language, `seriesIndex REAL` (fractional indices
  are load-bearing for novellas), and first-class state flags:
  `wantToRead`, `isFinished` + `dateFinished`, `lastOpenedAt` (Apple
  Books treats these as flags, not collections)
- `contributor` (name, `sortName`) ↔ `book_contributor` with a **role**
  (author/translator/narrator/editor) — RWPM roles; calibre's
  authors-only model is its known regret
- `series`, `tag` — normalized with link tables
- `identifier` (bookId, type, value) — an open bag, never an `isbn`
  column
- `format` — UUID, bookId, formatType, `originalFileName` (export/reveal
  only — the stored file is named `<formatUUID>.<ext>`, so collisions are
  impossible by construction *(R2-F3)*), byteSize, SHA-256 `contentHash`
- `format_local` — per-device, **never synced**: formatId, present flag,
  localVerifiedAt. A Format record is device-independent; binary
  *availability* is per-device. *(R2-F5)*
- `collection` (manual + smart with a stored rule) and `collection_book`
  as a **first-class synced record**: own UUID, collectionId, bookId,
  fractional `orderKey` (LexoRank-style, so concurrent same-position
  inserts don't collide), tombstone. *(R2-F6)*
- `field_lock` — bookId, field, locked BOOL; **one record per locked
  field**, individually versioned and merged like any other record.
  Enrichment and sync field-LWW both consult it; a JSON lock-list column
  was reviewed and rejected as non-convergent. *(R2-F10)*
- `reading_state` — per (book, format): `currentLocator` JSON, durable
  `candidates` JSON, `highWaterMark`; device attribution lives inside
  each locator/candidate entry, not at row level *(R2-F9)*
- `annotation` — UUID, type (highlight/note/bookmark), locator JSON
  (range CFI or PDF quads), color, note text, timestamps, tombstone
- `import_item` — **local-only** durable import/quarantine state: id,
  source (security-scoped bookmark + display path), status
  (pending/importing/quarantined/failed/done), errorCode, message,
  attemptCount, timestamps, nullable resulting bookId. The quarantine UI
  filters this table; retry re-resolves the bookmark; survives relaunch
  by construction. *(R2-F8)*
- **FTS5 in a separate ATTACHed database file** (calibre's pattern):
  `book_fts` (title/authors/series/tags/description) + `content_fts`
  (per spine item), hash-gated so unchanged files never re-index,
  rebuildable without touching the catalogue

## Disk layout & durability

`Application Support/Library/Books/<bookUUID>/` holds the format files
(`<formatUUID>.<ext>`), a **RWPM-shaped `metadata.json`** sidecar,
`cover.jpg`, and **`userdata.json`** — that book's annotations and
reading state, serialized as records *including tombstones* with their
apply sequences, flushed debounced (a delete schedules a flush exactly
like an add). A library-level **`collections.json`** covers cross-book
curation, and rotating **`VACUUM INTO` snapshots** of the catalogue DB
back up whatever sidecars can't represent. *(R2-F1, F11)*

Opaque UUID folders, not Author/Title paths (calibre's human-readable
paths force folder renames on every metadata edit); a "Reveal/Export"
command covers the human need. Thumbnails (2–3 fixed sizes, generated at
import, never at scroll time) and comic extractions live in Caches,
evictable.

**Crash-safe import protocol** *(R2-F2)* — SQLite transactions cannot
cover filesystem writes, so: (1) copy into `Books/.staging/<uuid>/` +
fsync; (2) write sidecars there; (3) atomic directory rename into place;
(4) DB insert committed **last**. Startup reconciliation sweep: staging
dirs are deleted (source file still at origin); book folders without DB
rows are **adopted from their sidecars** (the sidecar makes every folder
self-describing); DB rows without folders are marked missing and
surfaced. Folder-before-row ordering means a crash can only produce an
adoptable orphan, never a dangling row.

**Restore is a merge, not a file preference** *(R2-F11, F13)*: per-record
highest-apply-sequence wins with tombstone precedence, across live DB
remnant, sidecars, and snapshots. No mtime, no "sidecar unless missing."
"Restore Library" recovers: catalogue + files (sidecars), annotations +
positions (userdata sidecars), collections (collections.json), remainder
(newest snapshot). Import queue state is deliberately not restore-worthy.

## Import pipeline (stages, in order)

1. **Sniff** by magic bytes, not extension
2. **Classify** — DRM detection and unsupported variants → quarantine
   (`import_item`) with user-facing states
3. **Extract metadata natively** (OPF / EXTH / PDF info / ComicInfo.xml)
   — local-only, no network (Audiobookshelf's scan-vs-match separation)
4. **Covers + thumbnails**
5. **Dedupe ladder** *(R2-F4, F5)* — exact `contentHash` match: if the
   binary is missing locally, **hydrate** (adopt this file as the local
   copy, verify hash — same operation later serves CKAsset download);
   else skip. Identifier match: **prompt** as a merge candidate, default
   action "attach as format of existing book" — never silent (dirty
   ISBNs, sample-vs-full); a preference may promote to auto. Normalized
   title+author match: ask, biased toward asking.
6. **Stage, rename, insert** per the crash-safe protocol above
7. **Background FTS extraction** via a persisted queue (Komga's
   tasks-survive-restart pattern); MOBI body text lazy

Entry points: Files/Finder "Open with" (UTI `org.idpf.epub-container`,
`com.adobe.pdf`, …), share sheet, drag-drop onto the library window, and
a bulk-import folder picker. **Online metadata enrichment** (Google
Books/Open Library) is a separate, user-triggered step that skips locked
fields (`field_lock`) so a refresh never clobbers manual edits.

## Sync (later milestone; schema-ready now)

CKSyncEngine (requires iOS 17/macOS 14 — compatible with raising the
deployment floors by the time M7 ships), private database. Record types
mirror the synced tables
(Book, Format, Collection, CollectionBook, FieldLock, ReadingState,
Annotation) — `format_local` and `import_item` never sync. Merge rules:
annotations merge by UUID with permanent tombstones (tombstone beats
concurrent edit) and field-LWW only for edits to the same live
annotation; reading state follows the causal-candidates contract;
catalogue metadata is field-level LWW with `field_lock` consulted first.
Book *binaries* are explicitly phase-2-of-sync (CKAsset vs iCloud Drive
container decided then; local hydration paths already exist via the
dedupe ladder); metadata/positions/annotations sync first and deliver
most of the value.

## App structure

SwiftUI multiplatform, one codebase: a **Library scene**
(`NavigationSplitView`: sidebar = shelves/collections; content =
grid/list with sort/search; Reading Now shelf as home) and a **Reader
scene** hosting whichever navigator the format demands behind shared
chrome (TOC, annotations list, in-book search, appearance popover,
progress scrubber). On macOS each book opens in its own window with
menu-bar commands; on iPadOS multiwindow via scenes. The
quarantine/import-error surface is a filterable library state backed by
`import_item`, not a buried log.

## Build order

- **M1 — Catalogue core:** GRDB schema + migrations, crash-safe import
  for EPUB/PDF, library UI (browse/search/collections). *A useful
  organizer already.*
- **M2 — EPUB reading:** foliate-js bridge, scheme handler, pagination,
  position persistence, appearance settings. *The hard, load-bearing
  milestone.*
- **M3 — Annotations + in-book search + TOC** (EPUB), annotations list UI
- **M4 — PDF + comics navigators** (PDFKit chrome, quad-point highlights;
  archive cache + pager)
- **M5 — MOBI** (EXTH extractor, direct render, lazy FTS, quarantine
  states)
- **M6 — Polish toward parity:** Reading Now, smart collections, stats,
  dictionary lookup, more themes, annotation export (differentiator)
- **M7 — CloudKit sync** (positions/annotations/collections first,
  binaries later)

## Testing & error handling

IqraCore and IqraLibrary are pure Swift — unit-test the import pipeline
against a fixture corpus (valid books plus a "gauntlet": corrupt zip,
huge single-chapter EPUB, RTL, vertical CJK, fixed-layout, DRM'd files
that must quarantine, duplicate imports exercising every dedupe rung
including hydration). Crash-recovery tests kill the pipeline between
protocol steps and assert the reconciliation sweep's invariants. Restore
tests corrupt the DB and assert per-record merge outcomes including
tombstone precedence. Locator round-tripping gets a JS-side test harness
(CFI ↔ Range ↔ re-anchor). Navigator protocols get a mock conformance so
reader chrome is testable without WebKit. Corrupt/missing resources
inside books render placeholders rather than failing the chapter; every
import failure is a typed, user-visible state in `import_item`.
