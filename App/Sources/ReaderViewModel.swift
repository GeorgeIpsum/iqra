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
            _ = try? readingState.saveLocator(json: json, totalProgression: locator.totalProgression,
                                              bookID: bookID, formatID: formatID)
        }
    }

    func navigator(didFail message: String) {
        readerError = message
    }
}
