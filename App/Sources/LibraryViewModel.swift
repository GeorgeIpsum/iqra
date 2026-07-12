import Foundation
import Observation
import IqraCore
import IqraLibrary

@Observable @MainActor
final class LibraryViewModel {
    private(set) var books: [BookListItem] = []
    private(set) var quarantined: [ImportItemRecord] = []
    private(set) var isReady = false
    var searchText = "" { didSet { Task { await refreshSearch() } } }
    var sort: BookSort = .titleSort { didSet { Task { await restartObservation() } } }
    var lastError: String?
    var pendingIdentifierMatches: [(sourceURL: URL, existingBookID: UUID)] = []

    private var importErrors: [String] = []
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
            isReady = true
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
        guard let pipeline, let store else {
            lastError = "The library isn't ready yet. Please try again in a moment."
            return
        }
        var batchErrors: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try pipeline.importFile(at: url)
                if case let .needsUserDecision(existingBookID) = result {
                    pendingIdentifierMatches.append((url, existingBookID))
                }
            } catch {
                batchErrors.append("Import failed for \(url.lastPathComponent): \(error)")
            }
        }
        if !batchErrors.isEmpty {
            importErrors.append(contentsOf: batchErrors)
            lastError = importErrors.joined(separator: "\n")
        }
        quarantined = (try? store.quarantinedItems()) ?? quarantined
    }

    /// Pops and resolves the first queued identifier-match prompt. The alert re-presents
    /// automatically while the queue is non-empty (see `LibraryView`).
    func resolveIdentifierMatch(attach: Bool) async {
        guard !pendingIdentifierMatches.isEmpty else { return }
        let pending = pendingIdentifierMatches.removeFirst()
        guard let pipeline else {
            importErrors.append("Couldn't resolve match for \(pending.sourceURL.lastPathComponent): library isn't ready.")
            lastError = importErrors.joined(separator: "\n")
            return
        }
        let scoped = pending.sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { pending.sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            _ = try pipeline.importFile(
                at: pending.sourceURL,
                resolution: attach ? .attach(toBook: pending.existingBookID) : .importAsNewBook)
        } catch {
            importErrors.append("\(error)")
            lastError = importErrors.joined(separator: "\n")
        }
    }

    /// Discards the first queued identifier-match prompt without importing it (user tapped Cancel).
    func cancelPendingIdentifierMatch() {
        guard !pendingIdentifierMatches.isEmpty else { return }
        pendingIdentifierMatches.removeFirst()
    }

    /// Clears the error alert's state, including any accumulated batch-import errors.
    func dismissError() {
        lastError = nil
        importErrors.removeAll()
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
