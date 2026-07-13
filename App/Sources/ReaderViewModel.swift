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

    // M3 state
    private(set) var annotations: [Annotation] = []
    private(set) var currentSelection: SelectionInfo?
    private(set) var activeAnnotation: Annotation?

    var settings: ReaderSettings {
        didSet {
            navigator.apply(settings: settings)
            ReaderSettingsStore.save(settings)
        }
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
            initialLocator: initial,
            settings: ReaderSettingsStore.load())
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
    }

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
