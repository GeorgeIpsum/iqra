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
