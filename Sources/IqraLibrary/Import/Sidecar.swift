import Foundation
import IqraCore

/// Per-book metadata.json: makes every book folder self-describing so the DB is a
/// rebuildable index and orphan folders can be adopted (spec "Disk layout & durability").
public struct Sidecar: Codable, Equatable {
    public struct FormatEntry: Codable, Equatable {
        public let formatID: UUID
        public let formatType: FormatType
        public let originalFileName: String
        public let byteSize: Int64
        public let contentHash: String
        public init(formatID: UUID, formatType: FormatType, originalFileName: String,
                    byteSize: Int64, contentHash: String) {
            self.formatID = formatID; self.formatType = formatType
            self.originalFileName = originalFileName; self.byteSize = byteSize
            self.contentHash = contentHash
        }
    }
    public let bookID: UUID
    public let metadata: ExtractedMetadata
    public let formats: [FormatEntry]
    public let applySeq: Int64

    public init(bookID: UUID, metadata: ExtractedMetadata, formats: [FormatEntry], applySeq: Int64) {
        self.bookID = bookID; self.metadata = metadata; self.formats = formats; self.applySeq = applySeq
    }

    public static func write(_ sidecar: Sidecar, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> Sidecar {
        try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: url))
    }
}
