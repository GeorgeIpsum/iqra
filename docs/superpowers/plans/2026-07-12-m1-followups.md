# M1 Follow-ups (ticketed from the final whole-branch review)

Source: final review of branch `m1-catalogue-core` (d8a8959..4c6f565), verdict
"ready to merge" with these items consciously deferred. Schedule the Early-M2
block at the start of M2 (EPUB reading) or as a short M1.5 hardening pass.

## Early M2 (correctness/UX seams the reviewer flagged as real)

1. ~~**import_item crash/pending reconciliation + bookmark persistence.**
   Sweep gains a phase that marks stale `importing` rows `failed`; recovery UI
   query includes `pending`; `sourceBookmark` (security-scoped) actually stored
   at first upsert so retry can re-access files under sandbox.~~
   **DONE (M2)** — `ec80bc7` (import_item crash recovery, pending rows in
   recovery UI, source bookmarks).
2. ~~**Sweep reconciles sidecar-ahead-of-DB formats for KNOWN books** (attach
   crash window leftovers; also `.partial` temp-file cleanup and adoption
   passing through the dedupe ladder to avoid duplicate books on retry).~~
   **DONE (M2)** — `2dc7afd` (sweep reconciles attach-crash leftovers, stale
   partials, duplicate orphans), `4f4a915` (isolate duplicate-hash check).
3. ~~**Thumbnail backfill:** sweep adoption runs ThumbnailPipeline from the
   folder's cover.jpg; `coverURL(for:)` falls back to `paths.cover(bookID:)`
   when the Caches thumbnail is missing (Caches purge recovery).~~
   **DONE (M2)** — `5b6db4f` (thumbnail backfill on adoption and cover
   fallback after cache purge).
4. ~~**Off-main-actor import:** `importFiles` moves off the MainActor
   (ImportPipeline made Sendable-safe or dispatched); streaming SHA-256 in
   `sha256Hex` (currently whole-file `Data(contentsOf:)`).~~
   **DONE (M2)** — `b9e315a` (streaming SHA-256 and off-main-actor batch
   import).

## M2 app-shell polish batch

- Conflict alert shows the filename; queued-alert re-present verified in the
  smoke test; debounced search; search respects selected sort + live-updates;
  async CoverView loading; sweep off the launch MainActor path; dual-alert
  contention check.
  (Status as of M2 close: **0/7 implemented** — Task 11 verified none of these
  landed during M2; they remain open. Do not mark done without code.)

## Deferred from M3 (branch m3-annotations-search)

M3 shipped annotation persistence (highlights in 5 colors, sticky notes, bookmarks) and reader-side in-book full-text search, both with complete EPUB navigator tests. These features remain open for M4 or later:

- **Catalogue FTS:** `content_fts` full-text search over the library catalogue is deferred (M3 shipped reader-side in-book search only; catalogue search remains by title/author prefix in the library UI).
- **In-text margin indicator for noted passages:** the annotation list shows the note glyph, but in-text glyphs at the margin are deferred (foliate single-style overlay; requires careful CSS isolation to avoid layout thrash).
- **Annotation export:** Markdown/CSV export of highlights and notes remains a M6 differentiator (M3 focused on read and inline edit).

## Deferred from M2 final whole-branch review (branch m2-epub-reading)

Merge verdict was "with fixes"; the merge-blockers were fixed (reader-VM
caching, mmap book reads, hostile-EPUB security test, deprecated-alias/ordering/
docs nits). These remain open for M3 or a hardening pass:

- **Reader open performance:** serve `book.epub` off the main thread (mmap is
  in place; the read + `didReceive` still run on the scheme-handler's main
  thread); cache the compiled `WKContentRuleList` app-wide instead of
  recompiling per navigator (`WKContentRuleListStore.lookUpContentRuleList`).
- **Whole-EPUB memory posture:** the design holds the book as bytes in Swift
  (now mmap'd) AND as a `Blob` in the content process (`useWebWorkers: false`);
  measure against a large image-heavy EPUB before trusting the smoke test on
  real books.
- **Test flakiness (confirmed):** a full `swift test` run intermittently shows
  1 failure that passes on rerun and under per-suite filtering — WebKit suites
  and the shared `WKContentRuleListStore.default()` identifier are the
  suspects. Named ticket: loop-run with full failure capture to identify the
  flaky test, then serialize the WebKit-backed tests.
- **Import batch serialization:** two quick file drops can spawn two concurrent
  `Task.detached` batches; the `@unchecked Sendable` contract assumes serial
  batches. Route batches through one actor/queue.
- **Crash-leak dispositions:** attach-crash between file-move and sidecar-write
  leaks an unreferenced format file no sweep phase reclaims; duplicate-orphan
  folders are re-skipped and re-counted every launch with no terminal state.
- **Reader test coverage:** hostile-EPUB test shipped (security HELD); still
  want direct `index.html`/`bridge.js` scheme-path resolver tests and an
  xcodebuild harness exercising the macOS `Contents/Resources` bundle layout.
- **macOS arrow-key paging** (`ReaderScreen.onKeyPress`) may be swallowed once
  the WKWebView is first responder — confirm in the smoke test.

## Manual smoke test — STILL OWED (M1 Task 12 Step 5 + M2 Task 11 Step 5)

Both milestones' human smoke passes are unrun. M2 adds: open an EPUB from the
library → it renders paginated → arrow keys / swipe turn pages → progress %
updates → quit mid-book → relaunch → reopen → position restored (± one page) →
appearance popover applies dark theme + larger text live → switch to Scroll
layout → TOC navigates to a chapter. On iOS Simulator: same book, swipe, rotate.

## Before first user-visible release (pre-release schema edits are free)

- **Plan-level decision:** `identifier` / `book_contributor` / `book_tag` lack
  `applySeq`/tombstones. Current stance: they sync inside the Book record's
  payload (spec sync section). Final reviewer challenges this for M7; decide
  and, if needed, edit migration v1 BEFORE any build reaches users.
- **FTS rebuild path:** catalogue and fts DBs are separate ATTACHed files; WAL
  gives no cross-DB atomicity, and "FTS is rebuildable" has no rebuild code
  yet. Add a rebuild/consistency check before search correctness matters.

## Test-only deferrals (fold into the M5 gauntlet corpus)

- Sniffer: zip with wrong mimetype content, corrupt PK zip, 0-byte file.
- Namespaced container.xml / encryption.xml fixtures (parsers currently
  fail closed without `shouldProcessNamespaces`).
- PDF: empty-string info-dict values; zero-page valid PDF.
- ThumbnailPipeline: per-size failure on valid source returns `.written`
  silently (consider a `.partial` result).
- makeTitleSort: doubled internal whitespace, lowercase articles.
- authorSort tie-breaking; group_concat `ORDER BY` aggregate once the SQLite
  floor reaches 3.44.

## Manual smoke test still owed (plan Task 12, Step 5)

On macOS: launch, import an EPUB and a PDF (covers/titles appear), search by
author prefix, re-import the same EPUB (no duplicate), import two books
sharing an ISBN (conflict prompt appears — try both buttons; with 2+
conflicts queued, verify the second prompt re-presents), quit + relaunch
(library persists).
