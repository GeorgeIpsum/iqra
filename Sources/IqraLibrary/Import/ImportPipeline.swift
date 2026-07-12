import Foundation
import CryptoKit
import GRDB
import IqraCore

public enum ImportResult: Equatable, Sendable {
    case imported(bookID: UUID)
    case attached(bookID: UUID, formatID: UUID)
    case hydrated(formatID: UUID)
    case skippedExactDuplicate(formatID: UUID)
    case quarantined(ImportRejection)
    case needsUserDecision(existingBookID: UUID)
}

public enum IdentifierResolution: Sendable {
    case ask, importAsNewBook, attach(toBook: UUID)
}

public func sha256Hex(of url: URL) throws -> String {
    let data = try Data(contentsOf: url) // M1: whole-file read; stream if profiling demands
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public final class ImportPipeline {
    let store: LibraryStore
    let dbm: DatabaseManager
    let paths: LibraryPaths
    let caches: LibraryPaths.Caches

    enum Failpoint { case afterStaging, afterRename, afterAttachFileMove, afterAttachSidecar }
    struct FailpointError: Error {}
    /// A real (non-simulated) error: the on-disk contentHash for a format didn't match the
    /// hash the caller matched on. Distinct from `FailpointError`, which exists solely to
    /// simulate process death in tests — this can actually happen (e.g. bit rot, a hash
    /// collision in a synced record) and must go through the normal failed-import path.
    struct HashMismatchError: Error {}
    var failpoint: Failpoint?
    private func hit(_ point: Failpoint) throws {
        if failpoint == point { throw FailpointError() }
    }

    public init(store: LibraryStore, dbm: DatabaseManager, paths: LibraryPaths,
                caches: LibraryPaths.Caches) {
        self.store = store; self.dbm = dbm; self.paths = paths; self.caches = caches
    }

    @discardableResult
    public func importFile(at url: URL, resolution: IdentifierResolution = .ask) throws -> ImportResult {
        // A resolving call (.attach/.importAsNewBook) settles a decision an earlier .ask call
        // already recorded as a "pending" import_item row for this path — reuse that row's id
        // instead of minting a new one, so the pending row reaches a terminal status instead
        // of being orphaned forever.
        let itemID = try reusableItemID(path: url.path, resolution: resolution)
        try upsertImportItem(id: itemID, path: url.path, status: "importing", rejection: nil, bookId: nil)

        do {
            // 1. sniff — magic bytes, never extension
            guard case let .recognized(formatType) = try FormatSniffer.sniff(fileURL: url),
                  formatType == .epub || formatType == .pdf else {
                // cbz/cbr/mobi arrive in M4/M5; everything unrecognized or not-yet-supported quarantines
                try upsertImportItem(id: itemID, path: url.path, status: "quarantined",
                                     rejection: .unsupportedFormat, bookId: nil)
                return .quarantined(.unsupportedFormat)
            }

            // 2–4. classify + extract metadata + cover (native, local-only)
            let extraction = formatType == .epub
                ? EPUBMetadataExtractor.extract(fileURL: url)
                : PDFMetadataExtractor.extract(fileURL: url)
            guard case let .extracted(metadata, coverData) = extraction else {
                guard case let .rejected(reason) = extraction else { fatalError("unreachable") }
                try upsertImportItem(id: itemID, path: url.path, status: "quarantined",
                                     rejection: reason, bookId: nil)
                return .quarantined(reason)
            }

            // 5. dedupe ladder
            let hash = try sha256Hex(of: url)
            switch try dedupe(hash: hash, identifiers: metadata.identifiers, resolution: resolution) {
            case let .skipExactDuplicate(formatID):
                try upsertImportItem(id: itemID, path: url.path, status: "done", rejection: nil, bookId: nil)
                return .skippedExactDuplicate(formatID: formatID)
            case let .hydrate(formatID):
                try hydrate(formatID: formatID, from: url, hash: hash, type: formatType)
                try upsertImportItem(id: itemID, path: url.path, status: "done", rejection: nil, bookId: nil)
                return .hydrated(formatID: formatID)
            case let .askIdentifierMatch(existingBookID):
                try upsertImportItem(id: itemID, path: url.path, status: "pending", rejection: nil, bookId: nil)
                return .needsUserDecision(existingBookID: existingBookID)
            case .newBook:
                break
            }

            if case let .attach(bookID) = resolution {
                let formatID = try attach(url: url, to: bookID, type: formatType,
                                          hash: hash, metadata: metadata)
                try upsertImportItem(id: itemID, path: url.path, status: "done",
                                     rejection: nil, bookId: bookID.uuidString)
                return .attached(bookID: bookID, formatID: formatID)
            }

            // 6. stage → atomic rename → DB row LAST (spec crash-safe protocol)
            let bookID = UUID(), formatID = UUID()
            let staging = paths.stagingBookDir(bookID)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let stagedFile = staging.appendingPathComponent("\(formatID.uuidString).\(formatType.fileExtension)")
            try FileManager.default.copyItem(at: url, to: stagedFile)
            try fsync(stagedFile)
            let byteSize = (try FileManager.default.attributesOfItem(atPath: stagedFile.path)[.size] as? Int64) ?? 0
            let sidecar = Sidecar(
                bookID: bookID, metadata: metadata,
                formats: [.init(formatID: formatID, formatType: formatType,
                                originalFileName: url.lastPathComponent,
                                byteSize: byteSize, contentHash: hash)],
                applySeq: 0) // stamped properly on adoption/insert; sidecar seq updated post-insert in later milestones
            try Sidecar.write(sidecar, to: staging.appendingPathComponent("metadata.json"))
            if let coverData {
                try coverData.write(to: staging.appendingPathComponent("cover.jpg"), options: .atomic)
            }
            try hit(.afterStaging)

            let finalDir = paths.bookDir(bookID)
            try FileManager.default.moveItem(at: staging, to: finalDir) // atomic rename, same volume
            try hit(.afterRename)

            try ThumbnailPipeline.process(coverData: coverData, bookID: bookID, paths: paths, caches: caches)
            try store.insertBook(metadata: metadata, formatType: formatType,
                                 originalFileName: url.lastPathComponent, byteSize: byteSize,
                                 contentHash: hash, bookID: bookID, formatID: formatID)
            try upsertImportItem(id: itemID, path: url.path, status: "done",
                                 rejection: nil, bookId: bookID.uuidString)
            return .imported(bookID: bookID)
        } catch let error as FailpointError {
            // Failpoints simulate process death: a real crash can't write anything more, so
            // the row must stay exactly as the last real write left it (typically "importing").
            // The crash-simulation tests depend on this — do not touch the DB here.
            throw error
        } catch {
            // A real thrown error (I/O, corruption, etc.): the schema has a terminal "failed"
            // status for exactly this case — use it instead of leaving the row stuck.
            try? upsertImportItem(id: itemID, path: url.path, status: "failed",
                                  rejection: nil, bookId: nil, message: String(describing: error))
            throw error
        }
    }

    // MARK: - ladder

    private func dedupe(hash: String, identifiers: [BookIdentifier],
                        resolution: IdentifierResolution) throws -> DedupeDecision {
        try dbm.writer.read { db in
            if let row = try Row.fetchOne(db, sql: """
                SELECT f.id, fl.present FROM format f
                JOIN format_local fl ON fl.formatId = f.id
                JOIN book b ON b.id = f.bookId AND b.deleted = 0
                WHERE f.contentHash = ? AND f.deleted = 0
                """, arguments: [hash]) {
                let formatID = UUID(uuidString: row["id"])!
                return (row["present"] as Bool)
                    ? .skipExactDuplicate(formatID: formatID)
                    : .hydrate(formatID: formatID)
            }
            if case .ask = resolution {
                for ident in identifiers where ident.type != "uuid" {
                    if let bookId = try String.fetchOne(db, sql: """
                        SELECT i.bookId FROM identifier i JOIN book b ON b.id = i.bookId
                        WHERE i.type = ? AND i.value = ? AND b.deleted = 0
                        """, arguments: [ident.type, ident.value]) {
                        return .askIdentifierMatch(existingBookID: UUID(uuidString: bookId)!)
                    }
                }
            }
            return .newBook
        }
    }

    private func hydrate(formatID: UUID, from url: URL, hash: String, type: FormatType) throws {
        let (bookIdString, storedHash) = try dbm.writer.read { db -> (String, String) in
            let row = try Row.fetchOne(db, sql: "SELECT bookId, contentHash FROM format WHERE id = ?",
                                       arguments: [formatID.uuidString])!
            return (row["bookId"], row["contentHash"])
        }
        guard storedHash == hash else { throw HashMismatchError() } // defensive; caller matched on hash
        let bookID = UUID(uuidString: bookIdString)!
        let dest = paths.formatFile(bookID: bookID, formatID: formatID, type: type)
        try FileManager.default.createDirectory(at: paths.bookDir(bookID), withIntermediateDirectories: true)
        let tmp = dest.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: url, to: tmp)
        try fsync(tmp)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        try dbm.writer.write { db in
            try db.execute(sql: """
                UPDATE format_local SET present = 1, missing = 0, localVerifiedAt = ? WHERE formatId = ?
                """, arguments: [Date(), formatID.uuidString])
        }
    }

    // Crash-safe ordering mirrors the main import path: all filesystem state (file, then
    // sidecar) lands before the DB row. A crash after the file move but before the DB row
    // leaves an orphaned <formatUUID>.<ext> file with no sidecar/DB trace — an invisible
    // leak the sweep doesn't reconcile yet (ticketed for M2), but harmless because nothing
    // references it. A crash after the sidecar write leaves the sidecar listing a format the
    // DB doesn't know about yet — the self-describing-folder invariant (sidecar ⊇ DB formats
    // for the book) still holds, so a rebuild-from-sidecar would recover the format whose
    // file already exists on disk.
    private func attach(url: URL, to bookID: UUID, type: FormatType,
                        hash: String, metadata: ExtractedMetadata) throws -> UUID {
        let formatID = UUID()

        // 1. copy+fsync the file into place.
        let dest = paths.formatFile(bookID: bookID, formatID: formatID, type: type)
        let tmp = dest.appendingPathExtension("partial")
        try FileManager.default.copyItem(at: url, to: tmp)
        try fsync(tmp)
        try FileManager.default.moveItem(at: tmp, to: dest)
        let byteSize = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        try hit(.afterAttachFileMove)

        // 2. update the sidecar so the folder stays self-describing.
        let sidecarURL = paths.metadataSidecar(bookID: bookID)
        if let sidecar = try? Sidecar.read(from: sidecarURL) {
            let updated = Sidecar(bookID: sidecar.bookID, metadata: sidecar.metadata,
                              formats: sidecar.formats + [.init(formatID: formatID, formatType: type,
                                                                originalFileName: url.lastPathComponent,
                                                                byteSize: byteSize, contentHash: hash)],
                              applySeq: sidecar.applySeq)
            try Sidecar.write(updated, to: sidecarURL)
        }
        try hit(.afterAttachSidecar)

        // 3. DB row last.
        try dbm.writer.write { db in
            let seq = try dbm.nextApplySequence(db)
            try FormatRecord(id: formatID.uuidString, bookId: bookID.uuidString,
                             formatType: type.rawValue, originalFileName: url.lastPathComponent,
                             byteSize: byteSize, contentHash: hash, addedAt: Date(),
                             applySeq: seq, deleted: false).insert(db)
            try db.execute(sql: "INSERT INTO format_local (formatId, present, localVerifiedAt, missing) VALUES (?, 1, ?, 0)",
                           arguments: [formatID.uuidString, Date()])
        }
        return formatID
    }

    // MARK: - helpers

    private func fsync(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    /// Finds a "pending" import_item row for this path so a resolving call (anything but
    /// `.ask`) can settle it in place, rather than leaving it orphaned while a new row is
    /// created for the same import. Only "pending" rows are reused — a `.ask` call (which
    /// never resolves anything) always gets a fresh id.
    private func reusableItemID(path: String, resolution: IdentifierResolution) throws -> String {
        guard case .ask = resolution else {
            if let existing = try dbm.writer.read({ db in
                try String.fetchOne(db, sql: """
                    SELECT id FROM import_item WHERE status = 'pending' AND sourceDisplayPath = ?
                    ORDER BY updatedAt DESC LIMIT 1
                    """, arguments: [path])
            }) {
                return existing
            }
            return UUID().uuidString
        }
        return UUID().uuidString
    }

    private func upsertImportItem(id: String, path: String, status: String,
                                  rejection: ImportRejection?, bookId: String?,
                                  message: String? = nil) throws {
        try dbm.writer.write { db in
            try db.execute(sql: """
                INSERT INTO import_item (id, sourceBookmark, sourceDisplayPath, status, rejection,
                                         message, attemptCount, createdAt, updatedAt, bookId)
                VALUES (?, NULL, ?, ?, ?, ?, 1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET status = excluded.status,
                    rejection = excluded.rejection, message = excluded.message,
                    updatedAt = excluded.updatedAt, bookId = excluded.bookId
                """, arguments: [id, path, status, rejection?.rawValue, message, Date(), Date(), bookId])
        }
    }
}
