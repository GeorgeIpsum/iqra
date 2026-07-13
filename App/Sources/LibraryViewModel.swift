import Foundation
import Observation
import IqraCore
import IqraLibrary

@Observable @MainActor
final class LibraryViewModel {
    private(set) var books: [BookListItem] = []
    private(set) var readingState: ReadingStateStore?
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
            readingState = ReadingStateStore(dbm: dbm)
            pipeline = ImportPipeline(store: store, dbm: dbm, paths: paths, caches: caches)
            try ReconciliationSweep.run(paths: paths, store: store, dbm: dbm, caches: caches)
            quarantined = try store.quarantinedItems()
            await restartObservation()
            isReady = true
        } catch {
            lastError = "\(error)"
        }
    }

    func coverURL(for bookID: UUID) -> URL? {
        guard let caches, let paths else { return nil }
        let thumb = caches.thumbnail(bookID: bookID, size: .grid)
        if FileManager.default.fileExists(atPath: thumb.path) { return thumb }
        let cover = paths.cover(bookID: bookID)
        return FileManager.default.fileExists(atPath: cover.path) ? cover : nil
    }

    func readerModel(for bookID: UUID) -> ReaderViewModel? {
        guard let store, let readingState, let paths else { return nil }
        return ReaderViewModel(bookID: bookID, store: store,
                               readingState: readingState, paths: paths)
    }

    func importFiles(_ urls: [URL]) async {
        guard let pipeline, let store else {
            lastError = "The library isn't ready yet. Please try again in a moment."
            return
        }
        // Import work is CPU+IO heavy (copy, hash, unzip): run the batch off the MainActor.
        // The closure returns its results instead of mutating captured vars — mutating a
        // captured `var` from inside a `@Sendable` closure trips strict-concurrency capture
        // diagnostics, since the compiler can't see that the batch runs sequentially.
        let (batchErrors, conflicts): ([String], [(sourceURL: URL, existingBookID: UUID)]) =
            await Task.detached(priority: .userInitiated) {
                var batchErrors: [String] = []
                var conflicts: [(sourceURL: URL, existingBookID: UUID)] = []
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    #if os(macOS)
                    let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                         includingResourceValuesForKeys: nil, relativeTo: nil)
                    #else
                    let bookmark = try? url.bookmarkData()
                    #endif
                    do {
                        let result = try pipeline.importFile(at: url, sourceBookmark: bookmark)
                        if case let .needsUserDecision(existingBookID) = result {
                            conflicts.append((url, existingBookID))
                        }
                    } catch {
                        batchErrors.append("Import failed for \(url.lastPathComponent): \(error)")
                    }
                }
                return (batchErrors, conflicts)
            }.value
        pendingIdentifierMatches.append(contentsOf: conflicts)
        if !batchErrors.isEmpty {
            importErrors.append(contentsOf: batchErrors)
            lastError = importErrors.joined(separator: "\n")
        }
        quarantined = (try? store.recoveryItems()) ?? quarantined
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
            #if os(macOS)
            let bookmark = try? pending.sourceURL.bookmarkData(options: .withSecurityScope,
                                                               includingResourceValuesForKeys: nil, relativeTo: nil)
            #else
            let bookmark = try? pending.sourceURL.bookmarkData()
            #endif
            _ = try pipeline.importFile(
                at: pending.sourceURL,
                resolution: attach ? .attach(toBook: pending.existingBookID) : .importAsNewBook,
                sourceBookmark: bookmark)
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
