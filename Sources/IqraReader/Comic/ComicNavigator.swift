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
            if let loaded = ComicExtractor.loadManifest(from: cacheDir) {
                manifest = loaded
            } else {
                manifest = try ComicExtractor.extractCBZ(cbzURL: comicFileURL, into: cacheDir)
            }
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
