import Foundation
import GRDB
import IqraCore

public struct SweepReport: Equatable, Sendable {
    public var stagingDeleted = 0
    public var orphansAdopted = 0
    public var formatsMarkedMissing = 0
    /// Items whose per-item repair failed (bad orphan adoption, bad missing-binary update).
    /// The sweep isolates these instead of letting one bad item abort the whole run.
    public var failures = 0
    /// Rows whose import was cut off by a crash and marked 'failed' by this sweep.
    public var staleImportsFailed = 0
    public init() {}
}

public enum ReconciliationSweep {
    @discardableResult
    public static func run(paths: LibraryPaths, store: LibraryStore,
                           dbm: DatabaseManager) throws -> SweepReport {
        var report = SweepReport()
        let fm = FileManager.default

        // 1. staging leftovers: import never completed; source file is still at origin. Delete.
        if let staged = try? fm.contentsOfDirectory(at: paths.stagingDir, includingPropertiesForKeys: nil) {
            for url in staged {
                try fm.removeItem(at: url)
                report.stagingDeleted += 1
            }
        }

        // 2. orphan book folders (crash after rename, before DB row): adopt from sidecar.
        // Each folder is isolated: one bad/corrupt orphan (e.g. a bookID collision) must not
        // stop adoption of the rest, nor skip phase 3 below.
        let knownBookIDs: Set<String> = try dbm.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM book"))
        }
        if let folders = try? fm.contentsOfDirectory(at: paths.booksDir, includingPropertiesForKeys: nil) {
            for folder in folders where folder.lastPathComponent != ".staging" {
                let name = folder.lastPathComponent
                guard !knownBookIDs.contains(name) else { continue }
                guard let sidecar = try? Sidecar.read(from: folder.appendingPathComponent("metadata.json")),
                      let firstFormat = sidecar.formats.first else { continue } // undescribed folder: leave for the user
                do {
                    try store.insertBook(metadata: sidecar.metadata, formatType: firstFormat.formatType,
                                         originalFileName: firstFormat.originalFileName,
                                         byteSize: firstFormat.byteSize, contentHash: firstFormat.contentHash,
                                         bookID: sidecar.bookID, formatID: firstFormat.formatID)
                    // A multi-format book can crash into orphanhood too (ImportPipeline.attach
                    // appends to the sidecar's formats array) -- adopt every remaining format
                    // so none are silently dropped, mirroring the DB portion of attach().
                    for extra in sidecar.formats.dropFirst() {
                        let file = folder.appendingPathComponent(
                            "\(extra.formatID.uuidString).\(extra.formatType.fileExtension)")
                        let present = fm.fileExists(atPath: file.path)
                        try dbm.writer.write { db in
                            let seq = try dbm.nextApplySequence(db)
                            try FormatRecord(id: extra.formatID.uuidString, bookId: sidecar.bookID.uuidString,
                                             formatType: extra.formatType.rawValue,
                                             originalFileName: extra.originalFileName, byteSize: extra.byteSize,
                                             contentHash: extra.contentHash, addedAt: Date(),
                                             applySeq: seq, deleted: false).insert(db)
                            try db.execute(sql: """
                                INSERT INTO format_local (formatId, present, localVerifiedAt, missing)
                                VALUES (?, ?, ?, ?)
                                """, arguments: [extra.formatID.uuidString, present, present ? Date() : nil, !present])
                        }
                    }
                    report.orphansAdopted += 1
                } catch {
                    report.failures += 1
                }
            }
        }

        // 3. DB rows whose binary vanished: mark missing, surface in UI (never delete data).
        let rows: [(formatId: String, bookId: String, type: String)] = try dbm.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id AS formatId, f.bookId AS bookId, f.formatType AS type
                FROM format f JOIN format_local fl ON fl.formatId = f.id
                WHERE fl.present = 1 AND f.deleted = 0
                """).map { ($0["formatId"], $0["bookId"], $0["type"]) }
        }
        for row in rows {
            guard let bookID = UUID(uuidString: row.bookId),
                  let formatID = UUID(uuidString: row.formatId),
                  let type = FormatType(rawValue: row.type) else { continue }
            let file = paths.formatFile(bookID: bookID, formatID: formatID, type: type)
            if !fm.fileExists(atPath: file.path) {
                do {
                    try dbm.writer.write { db in
                        try db.execute(sql: """
                            UPDATE format_local SET present = 0, missing = 1 WHERE formatId = ?
                            """, arguments: [row.formatId])
                    }
                    report.formatsMarkedMissing += 1
                } catch {
                    report.failures += 1
                }
            }
        }

        // 4. import_item rows stuck at 'importing' can only mean a crash mid-import
        //    (every live code path ends in a terminal status or 'pending'). Mark them
        //    failed so the recovery UI can offer a retry via the stored bookmark.
        do {
            let stale = try dbm.writer.write { db in
                try db.execute(sql: """
                    UPDATE import_item
                    SET status = 'failed', message = 'Interrupted by a crash or forced quit',
                        updatedAt = ?
                    WHERE status = 'importing'
                    """, arguments: [Date()])
                return db.changesCount
            }
            report.staleImportsFailed = stale
        } catch {
            report.failures += 1
        }

        return report
    }
}
