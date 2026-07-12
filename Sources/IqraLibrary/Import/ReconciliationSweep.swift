import Foundation
import GRDB
import IqraCore

public struct SweepReport: Equatable, Sendable {
    public var stagingDeleted = 0
    public var orphansAdopted = 0
    public var formatsMarkedMissing = 0
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
        let knownBookIDs: Set<String> = try dbm.writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM book"))
        }
        if let folders = try? fm.contentsOfDirectory(at: paths.booksDir, includingPropertiesForKeys: nil) {
            for folder in folders where folder.lastPathComponent != ".staging" {
                let name = folder.lastPathComponent
                guard !knownBookIDs.contains(name) else { continue }
                guard let sidecar = try? Sidecar.read(from: folder.appendingPathComponent("metadata.json")),
                      let entry = sidecar.formats.first else { continue } // undescribed folder: leave for the user
                try store.insertBook(metadata: sidecar.metadata, formatType: entry.formatType,
                                     originalFileName: entry.originalFileName,
                                     byteSize: entry.byteSize, contentHash: entry.contentHash,
                                     bookID: sidecar.bookID, formatID: entry.formatID)
                report.orphansAdopted += 1
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
                try dbm.writer.write { db in
                    try db.execute(sql: """
                        UPDATE format_local SET present = 0, missing = 1 WHERE formatId = ?
                        """, arguments: [row.formatId])
                }
                report.formatsMarkedMissing += 1
            }
        }
        return report
    }
}
