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

## Deferred from M3 final whole-branch review (branch m3-annotations-search)

Merge verdict was "with fixes"; the six merge-blockers were fixed (persist/
delete error surfacing, search-spinner reset on error, selection-bar edge
clamp, NoteEditor accessibility, tombstone + cross-section-overlay tests).
These remain open:

- **M4 PRE-WORK (do BEFORE the PDF/comics navigators): capability-protocol
  split.** The spec mandates a base `Navigator` + `TextSelectable`/
  `RangeAnnotatable`/`Searchable` capability protocols so the UI can't offer
  highlighting on a CBZ page. M1–M3 put everything on one flat
  `NavigatorDelegate` + concrete `EPUBNavigator`. This must land before M4
  adds non-text navigators, not with them. Also fix the stale
  `NavigatorProtocols.swift` comment promising capability protocols "arrive
  with their features in M3/M4" — M3's features arrived without them.
- **Search-hit flood:** the bridge posts one message per hit and each does an
  @Observable List append; a common word in a full book = thousands of IPC
  round-trips + list diffs. foliate already yields hits batched per section
  (`subitems`) — post one message per section, or cap total hits (~500) with
  a "truncated" marker.
- **Search-result decorations cleared too eagerly:** tapping a result
  dismisses the sheet whose `onDismiss` calls `clearSearch()`, so the user
  lands on the passage with no visible match outline and loses query+results.
  Clear only on explicit Done.
- **createHighlight locator drops `spineHref`/`progressionInChapter`** (the
  bridge `selected` payload doesn't carry `spineHref`). The spec's composite
  locator wants it as the robust re-anchor key if a spine shifts — cheap to
  add now (bridge + Locator), annoying to backfill.
- **Bookmark identity is exact CFI-string equality:** change font size/width
  and the same page yields a different CFI (button reads un-bookmarked,
  toggle stacks a near-dup). Eventually use a fuzzy match (spine + progression
  tolerance).
- **NoteEditor Cancel doesn't revert a color change** (changeColor persists
  immediately). Apply color on Done, or rename the affordance.
- Minor polish carried from per-task reviews: selection-bar `onDismiss`
  unused (no tap-outside dismiss on native chrome); empty search query only
  clears on submit not live typing; highlights/bookmarks re-filtered per
  access in the list; `AnnotationStore.dbm` public (a `values(in:)`-wrapping
  method would hide `DatabaseManager`); dead `currentIndex` var in bridge.js
  (fix opportunistically); keyboard (Shift+Arrow) selection unreported
  (accessibility pass).

## Smoke-test finding (2026-07-16): WKWebView needs the network-client entitlement

The first human smoke test found the reader rendered nothing in the sandboxed
app (console spammed `RBSAssertionErrorDomain … "WebProcess … does not exist"`).
Root cause: a sandboxed macOS app using WKWebView must carry
`com.apple.security.network.client` or the WebContent process can't launch —
even for purely local custom-scheme content. Fixed by adding
`ENABLE_OUTGOING_NETWORK_CONNECTIONS: YES` to `App/project.yml`. **The package
tests can never catch this** — `swift test` runs unsandboxed. Guard idea (no CI
yet): a build-time check that greps the built `iqra.app`'s
`codesign -d --entitlements` for `network.client`, run as part of any release
step. macOS reader launch + render is now human-confirmed.

## Manual smoke test — M3 reader path CONFIRMED (2026-07-16, macOS)

Human-confirmed working after the network-client entitlement fix: EPUB opens
and renders paginated; select → color bar → highlight; note editor
(add/change-color/delete); bookmarks; tap-to-edit an existing highlight; and
highlights/notes/bookmarks all **restore on reopen**. Still unconfirmed by a
human (not blocking): in-book search end-to-end, the iOS build in a simulator,
and large/image-heavy-EPUB memory/perf.

## Manual smoke test — original M1/M2 items still owed

On macOS + iOS: open an EPUB → select text → color bar → pick a color →
highlight drawn → tap it → note editor → add note / change color / Done →
annotations list shows the note glyph → tap it → navigates back → **turn
several pages and back → the highlight is still drawn** (this create-overlay
redraw path is now unit-tested but never visually confirmed) → bookmark a
page, toggle off → Find in Book → results stream → tap one → navigates →
quit + relaunch → highlights/notes/bookmarks all restored.

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
