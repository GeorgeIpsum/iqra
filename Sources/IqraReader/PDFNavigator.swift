// Sources/IqraReader/PDFNavigator.swift
import Foundation
import PDFKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// PDFKit-backed navigator. The app hosts `pdfView` in a representable; all durable state
/// (position, annotations) is the caller's responsibility — the navigator reports position
/// via the delegate and never mutates the source file.
@MainActor public final class PDFNavigator: NSObject, Navigator, TextSelectable, RangeAnnotatable,
                                             AppearanceConfigurable {
    public let pdfView = PDFView()
    public weak var delegate: NavigatorDelegate?

    private let document: PDFDocument
    private let initialLocator: Locator?
    private var pageObserver: NSObjectProtocol?
    private var searchTask: Task<Void, Never>?
    private var selectionObserver: NSObjectProtocol?
    /// id -> the PDFAnnotations drawn for it (one per quad/line), so removeAnnotation and the
    /// tap hit-test can find/reverse-look-up them. In-memory only — never written to the file.
    private var pdfAnnotationsByID: [UUID: [PDFAnnotation]] = [:]

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
        selectionObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.emitSelection() }
        }
        installTapGesture()
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

    /// Reports the current text selection (or nil once cleared) via the delegate, carrying a
    /// full `Locator` (page index + page-space quads + the selected text) so the app can build
    /// a highlight `Annotation` from it uniformly with the EPUB path.
    private func emitSelection() {
        guard let sel = pdfView.currentSelection, !(sel.string ?? "").isEmpty,
              let anchor = PDFAnnotationMapping.anchor(from: sel, in: document),
              let page = sel.pages.first else { delegate?.navigator(didChangeSelection: nil); return }
        // rect for the popover: union of line bounds → view space
        let pageRect = sel.bounds(for: page)
        let viewRect = pdfView.convert(pageRect, from: page)
        let textContext = TextContext(before: "", highlight: anchor.textQuote, after: "")
        let locator = Locator(spineIndex: anchor.pageIndex, cfi: nil,
                              totalProgression: Self.pageLocator(pageIndex: anchor.pageIndex,
                                  pageCount: document.pageCount, tocLabel: nil).totalProgression,
                              textContext: textContext, pageQuads: anchor.quads)
        delegate?.navigator(didChangeSelection: SelectionInfo(
            text: anchor.textQuote, cfi: "",
            rect: SelectionRect(x: Double(viewRect.minX), y: Double(viewRect.minY),
                width: Double(viewRect.width), height: Double(viewRect.height)),
            spineIndex: anchor.pageIndex, totalProgression: locator.totalProgression,
            textContext: textContext, locator: locator))
    }

    /// Tap hit-test: resolve a tap on `pdfView` to a page point, then to a PDFAnnotation, then
    /// (if it's one we drew) to its stored id for `delegate?.navigator(didTapAnnotation:)`.
    private func installTapGesture() {
        #if os(iOS)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        pdfView.addGestureRecognizer(tap)
        #else
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        pdfView.addGestureRecognizer(click)
        #endif
    }

    #if os(iOS)
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        resolveTap(at: gesture.location(in: pdfView))
    }
    #else
    @objc private func handleTap(_ gesture: NSClickGestureRecognizer) {
        resolveTap(at: gesture.location(in: pdfView))
    }
    #endif

    private func resolveTap(at point: CGPoint) {
        guard let page = pdfView.page(for: point, nearest: true) else { return }
        let pagePoint = pdfView.convert(point, to: page)
        guard let hit = page.annotation(at: pagePoint) else { return }
        for (id, anns) in pdfAnnotationsByID where anns.contains(where: { $0 === hit }) {
            delegate?.navigator(didTapAnnotation: id)
            return
        }
    }

    public nonisolated static func pageLocator(pageIndex: Int, pageCount: Int, tocLabel: String?) -> Locator {
        let denom = Double(max(1, pageCount - 1))
        return Locator(spineIndex: pageIndex, cfi: nil,
                       totalProgression: Double(pageIndex) / denom, tocLabel: tocLabel)
    }

    /// Flatten the PDF outline into our TOCItem tree. `href` carries the destination page index
    /// as a string so the app can navigate via goTo(locator:).
    public nonisolated static func toc(from document: PDFDocument) -> [TOCItem] {
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

    deinit {
        if let o = pageObserver { NotificationCenter.default.removeObserver(o) }
        if let o = selectionObserver { NotificationCenter.default.removeObserver(o) }
    }
}

extension PDFNavigator {
    public func deselect() { pdfView.clearSelection() }
}

extension PDFNavigator {
    /// Draws one `.highlight` PDFAnnotation per stored quad directly on the in-memory
    /// `PDFPage` — this mutates the `PDFDocument` object graph only; the source file on disk
    /// is never touched (no `document.write` anywhere in this navigator).
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

extension PDFNavigator {
    public func apply(settings: ReaderSettings) {
        pdfView.backgroundColor = PlatformColor(hex: settings.theme.background)
        // (Page inversion for a true dark PDF is a PDFPage.draw override — deferred; background only.)
    }
}

extension PDFNavigator: Searchable {
    public func search(query: String) {
        clearSearch()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { delegate?.navigatorDidFinishSearch(); return }
        // Synchronous findString is fine for reader-sized PDFs. Once this Task's body starts
        // running, findString executes synchronously on the main thread like any other call —
        // wrapping it in a Task only defers the *start* past the current runloop tick (so
        // `search()` itself returns immediately) and mirrors the async feel of the EPUB search.
        searchTask = Task { @MainActor in
            let selections = document.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
            var drawn: [PDFSelection] = []
            var pageTextCache: [Int: String] = [:]
            var cursors: [Int: String.Index] = [:]
            for (ordinal, sel) in selections.enumerated() {
                if Task.isCancelled { return }
                guard let page = sel.pages.first else { continue }
                let idx = document.index(for: page)
                let match = sel.string ?? q
                if pageTextCache[idx] == nil { pageTextCache[idx] = page.string }
                let excerpt = Self.excerpt(in: pageTextCache[idx], match: match, searchFrom: cursors[idx])
                if let next = excerpt.next { cursors[idx] = next }
                sel.color = .yellow; drawn.append(sel)
                delegate?.navigator(didFindSearchHit: SearchHit(
                    cfi: "pdf:\(ordinal):\(idx)",   // globally unique per search: ordinal over all selections
                    excerptPre: excerpt.pre, excerptMatch: match, excerptPost: excerpt.post,
                    sectionLabel: nil,
                    locator: Self.pageLocator(pageIndex: idx, pageCount: document.pageCount, tocLabel: nil)))
            }
            guard !Task.isCancelled else { return }
            pdfView.highlightedSelections = drawn.isEmpty ? nil : drawn
            delegate?.navigatorDidFinishSearch()
        }
    }

    public func clearSearch() {
        searchTask?.cancel()
        pdfView.highlightedSelections = nil
    }

    /// ~40 chars of page text on either side of the match for the results list. `searchFrom`
    /// advances past prior occurrences on the same page so each hit gets the excerpt for its
    /// own occurrence rather than always the first one; `next` is where the following search
    /// on this page should resume from. Falls back to empty pre/post if the match can't be
    /// located (e.g. selection text disagrees with page.string extraction).
    private static func excerpt(in pageText: String?, match: String,
                                searchFrom start: String.Index?) -> (pre: String, post: String, next: String.Index?) {
        guard let pageText,
              let r = pageText.range(of: match, options: [], range: (start ?? pageText.startIndex)..<pageText.endIndex)
        else { return ("", "", nil) }
        let preStart = pageText.index(r.lowerBound, offsetBy: -40, limitedBy: pageText.startIndex) ?? pageText.startIndex
        let postEnd = pageText.index(r.upperBound, offsetBy: 40, limitedBy: pageText.endIndex) ?? pageText.endIndex
        return (String(pageText[preStart..<r.lowerBound]), String(pageText[r.upperBound..<postEnd]), r.upperBound)
    }
}
