// App/Sources/ReaderViewModel.swift
import Foundation
import Observation
import IqraCore
import IqraLibrary
import IqraReader

@Observable @MainActor
final class ReaderViewModel: NavigatorDelegate {
    let navigator: any Navigator
    private(set) var title: String?
    private(set) var toc: [TOCItem] = []
    private(set) var progressPercent: Int = 0
    private(set) var tocLabel: String?
    var readerError: String?

    // M3 state
    private(set) var annotations: [Annotation] = []
    private(set) var currentSelection: SelectionInfo?
    private(set) var activeAnnotation: Annotation?

    // search state
    private(set) var searchHits: [SearchHit] = []
    private(set) var isSearching = false
    var searchQuery = ""

    var settings: ReaderSettings {
        didSet {
            (navigator as? AppearanceConfigurable)?.apply(settings: settings)
            ReaderSettingsStore.save(settings)
        }
    }

    // Capability flags for the UI (so ReaderScreen shows/hides chrome per navigator kind).
    var canSelectText: Bool { navigator is TextSelectable }
    var canSearch: Bool { navigator is Searchable }
    var canConfigureAppearance: Bool { navigator is AppearanceConfigurable }

    private let bookID: UUID
    private let formatID: UUID
    private let readingState: ReadingStateStore
    private let annotationStore: AnnotationStore
    private var lastLocator: Locator?
    // @ObservationIgnored: this is private bookkeeping, not UI state, so it shouldn't be part
    // of the @Observable tracked-property machinery — and the macro's ObservationTracked
    // expansion doesn't allow a plain `nonisolated` modifier on a mutable stored property.
    // nonisolated(unsafe): deinit runs in a nonisolated context, so it can't touch a
    // MainActor-isolated stored property directly. The only concurrent access this enables is
    // Task.cancel() from deinit, which is documented as thread-safe; every mutation of the
    // task itself still happens on the MainActor (in startObservingAnnotations()).
    @ObservationIgnored
    private nonisolated(unsafe) var observationTask: Task<Void, Never>?

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
        guard let navigator = NavigatorFactory.make(
            formatType: type, bookID: bookID,
            formatURL: paths.formatFile(bookID: bookID, formatID: formatUUID, type: type),
            initialLocator: initial, settings: ReaderSettingsStore.load()) else { return nil }
        self.navigator = navigator
        navigator.delegate = self
        try? store.markOpened(bookID: bookID)
        startObservingAnnotations()
        navigator.start()
    }

    // Decode stored AnnotationRecords → reader Annotations, keep the observed list fresh,
    // and (re)push them to the navigator so overlays are drawn/redrawn.
    //
    // `self` is captured weakly and re-checked INSIDE the loop body (mirrors
    // LibraryViewModel.restartObservation()) rather than unwrapped once before it. Unwrapping
    // once up front would keep a strong reference to `self` alive for the entire lifetime of
    // the async sequence — which only ends when the DB writer closes or the process exits — so
    // the ReaderViewModel (and its EPUBNavigator/WKWebView) could never deallocate even after
    // LibraryViewModel drops its own reference on book switch.
    private func startObservingAnnotations() {
        let observation = annotationStore.observeAnnotations(bookID: bookID, formatID: formatID)
        let writer = annotationStore.dbm.writer
        observationTask = Task { [weak self] in
            do {
                for try await records in observation.values(in: writer) {
                    guard let self else { return }
                    let decoded: [Annotation] = records.compactMap { Self.annotation(from: $0) }
                    self.annotations = decoded
                    self.pushAnnotationsToReader(decoded)
                }
            } catch { /* db closed / cancelled */ }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    private func pushAnnotationsToReader(_ annotations: [Annotation]) {
        // Idempotent: the bridge keys overlays by CFI, so re-adding is a redraw, not a dupe.
        guard let annotatable = navigator as? RangeAnnotatable else { return }
        for a in annotations where a.kind != .bookmark { annotatable.addAnnotation(a) }
    }

    static func annotation(from r: AnnotationRecord) -> Annotation? {
        guard let id = UUID(uuidString: r.id),
              let kind = AnnotationKind(rawValue: r.kind),
              let locator = try? Locator.from(jsonData: Data(r.locator.utf8)) else { return nil }
        return Annotation(id: id, kind: kind, locator: locator,
                          color: r.color.flatMap(HighlightColor.init(rawValue:)),
                          note: r.noteText, createdAt: r.createdAt, modifiedAt: r.modifiedAt)
    }

    // MARK: NavigatorDelegate — every relocate commits to the DB before anything else
    // (spec: the DB, not the web view, is the source of truth).

    func navigatorDidLoad(title: String?, toc: [TOCItem]) {
        self.title = title
        self.toc = toc
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

    func navigator(didFail message: String) {
        readerError = message
        isSearching = false   // a JS error (e.g. mid-search) must not leave the spinner stuck
    }

    func navigator(didChangeSelection selection: SelectionInfo?) { currentSelection = selection }

    func navigator(didTapAnnotation id: UUID) {
        activeAnnotation = annotations.first { $0.id == id }
    }

    /// Clears the active annotation, e.g. when the note editor sheet is dismissed by the
    /// user (swipe-to-dismiss) rather than through an explicit Save/Cancel/Delete action.
    /// `activeAnnotation` is `private(set)` so `.sheet(item:)`'s two-way Binding needs this
    /// VM-owned setter to stay the single source of truth.
    func dismissActiveAnnotation() { activeAnnotation = nil }

    // MARK: NavigatorDelegate — search callbacks

    func navigator(didFindSearchHit hit: SearchHit) { searchHits.append(hit) }
    func navigatorDidFinishSearch() { isSearching = false }

    // MARK: Intents

    func runSearch() {
        guard let searchable = navigator as? Searchable else { return }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { clearSearch(); return }
        searchHits = []; isSearching = true
        searchable.search(query: q)
    }

    func clearSearch() {
        searchHits = []; isSearching = false; searchQuery = ""
        (navigator as? Searchable)?.clearSearch()
    }

    func goToHit(_ hit: SearchHit) {
        navigator.goTo(locator: hit.locator)
    }

    func clearSelection() { currentSelection = nil; (navigator as? TextSelectable)?.deselect() }

    // `sel.locator` is the selection's own format-neutral locator (EPUB: cfi+textContext; PDF:
    // spineIndex+pageQuads+textQuote) — one path builds a highlight `Annotation` for both.
    func createHighlight(color: HighlightColor) {
        guard let sel = currentSelection else { return }
        let annotation = Annotation(id: UUID(), kind: .highlight, locator: sel.locator, color: color,
                                    note: nil, createdAt: Date(), modifiedAt: Date())
        do {
            try persist(annotation)
            (navigator as? RangeAnnotatable)?.addAnnotation(annotation)
        } catch {
            readerError = "Couldn't save highlight: \(error)"
        }
        clearSelection()
    }

    func setNote(_ text: String, for annotation: Annotation) {
        var updated = annotation
        updated.note = text.isEmpty ? nil : text
        updated.kind = text.isEmpty ? .highlight : .note
        updated.modifiedAt = Date()
        do {
            try persist(updated)
            activeAnnotation = nil
        } catch {
            readerError = "Couldn't save note: \(error)"
        }
    }

    func changeColor(_ color: HighlightColor, for annotation: Annotation) {
        var updated = annotation; updated.color = color; updated.modifiedAt = Date()
        do {
            try persist(updated)
            (navigator as? RangeAnnotatable)?.addAnnotation(updated)   // redraw in place (same anchor key)
            if activeAnnotation?.id == annotation.id { activeAnnotation = updated }
        } catch {
            readerError = "Couldn't save highlight color: \(error)"
        }
    }

    func deleteAnnotation(_ annotation: Annotation) {
        do {
            try annotationStore.delete(id: annotation.id)
            (navigator as? RangeAnnotatable)?.removeAnnotation(annotation)
            if activeAnnotation?.id == annotation.id { activeAnnotation = nil }
        } catch {
            readerError = "Couldn't delete highlight: \(error)"
        }
    }

    func goTo(_ annotation: Annotation) { navigator.goTo(locator: annotation.locator) }

    // A TOC entry's `href` means different things per format: EPUB's is a file path/fragment
    // (e.g. "ch1.xhtml#x") that only EPUBNavigator.goTo(locator:) can resolve, via its cfi
    // branch; PDF's is a stringified destination page index (from PDFNavigator.toc(from:)),
    // and PDFNavigator.goTo(locator:) reads only spineIndex, ignoring cfi entirely. The two
    // formats are disjoint — an EPUB href is never a bare integer — so `Int(href)` reliably
    // tells us which one we're looking at and lets one method route correctly for both.
    func goToTOC(_ item: TOCItem) {
        guard let href = item.href else { return }
        if let page = Int(href) {
            navigator.goTo(locator: Locator(spineIndex: page, cfi: nil, totalProgression: 0))
        } else {
            navigator.goTo(locator: Locator(spineIndex: 0, cfi: href, totalProgression: 0))
        }
    }

    // MARK: Bookmarks

    // Decide existence against the DB directly rather than the in-memory `annotations` array:
    // that array only refreshes via the async `observeAnnotations` round-trip, so two rapid
    // (synchronous, back-to-back) toggle calls would both read the same pre-toggle snapshot
    // and both create a new bookmark at the same CFI. `annotationStore.annotations` does a
    // synchronous read through the same `DatabaseWriter` used to persist, so it is guaranteed
    // to observe a write that already returned — making the create/delete decision (and thus
    // idempotency by CFI) DB-true instead of cache-true. Reusing this existing store method
    // (rather than adding a new boolean-only `bookmarkExists`) also hands back the persisted
    // annotation itself, which the delete path needs anyway.
    private func bookmarkedAnnotation(at key: String) -> Annotation? {
        let fresh = (try? annotationStore.annotations(bookID: bookID, formatID: formatID)) ?? []
        return fresh.compactMap(Self.annotation(from:)).first { $0.kind == .bookmark && $0.locator.anchorKey == key }
    }

    var isCurrentPositionBookmarked: Bool {
        guard let key = lastLocator?.anchorKey else { return false }
        return annotations.contains { $0.kind == .bookmark && $0.locator.anchorKey == key }
    }

    func toggleBookmarkAtCurrentPosition() {
        guard let locator = lastLocator else { return }
        if let existing = bookmarkedAnnotation(at: locator.anchorKey) {
            deleteAnnotation(existing)
        } else {
            do {
                try persist(Annotation(id: UUID(), kind: .bookmark, locator: locator, color: nil,
                                       note: nil, createdAt: Date(), modifiedAt: Date()))
            } catch {
                readerError = "Couldn't save bookmark: \(error)"
            }
        }
    }

    private func persist(_ annotation: Annotation) throws {
        let json = try annotation.locator.jsonData()
        try annotationStore.upsert(id: annotation.id, bookID: bookID, formatID: formatID,
                                   kind: annotation.kind.rawValue, locatorJSON: json,
                                   color: annotation.color?.rawValue, noteText: annotation.note)
    }
}
