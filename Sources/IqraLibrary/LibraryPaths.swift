import Foundation
import IqraCore

/// All knowledge of the managed-library filesystem layout in one place (spec "Disk layout"):
/// <root>/Books/<bookUUID>/{<formatUUID>.<ext>, metadata.json, cover.jpg}, staging at Books/.staging.
public struct LibraryPaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public var booksDir: URL { root.appendingPathComponent("Books", isDirectory: true) }
    public var stagingDir: URL { booksDir.appendingPathComponent(".staging", isDirectory: true) }
    public func bookDir(_ bookID: UUID) -> URL {
        booksDir.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }
    public func stagingBookDir(_ bookID: UUID) -> URL {
        stagingDir.appendingPathComponent(bookID.uuidString, isDirectory: true)
    }
    public func formatFile(bookID: UUID, formatID: UUID, type: FormatType) -> URL {
        bookDir(bookID).appendingPathComponent("\(formatID.uuidString).\(type.fileExtension)")
    }
    public func metadataSidecar(bookID: UUID) -> URL {
        bookDir(bookID).appendingPathComponent("metadata.json")
    }
    public func cover(bookID: UUID) -> URL {
        bookDir(bookID).appendingPathComponent("cover.jpg")
    }

    public struct Caches: Sendable {
        public let root: URL
        public init(root: URL) { self.root = root }
        public func thumbnail(bookID: UUID, size: ThumbnailSize) -> URL {
            root.appendingPathComponent("thumbnails", isDirectory: true)
                .appendingPathComponent("\(bookID.uuidString)-\(size.rawValue).jpg")
        }
        /// Evictable cache dir for a comic format's extracted pages (spec: CBZ pages are
        /// extracted once into a cache, not stored in the managed library tree).
        public func comicPagesDir(formatID: UUID) -> URL {
            root.appendingPathComponent("comics", isDirectory: true)
                .appendingPathComponent(formatID.uuidString, isDirectory: true)
        }
    }
}

public enum ThumbnailSize: String, CaseIterable, Sendable {
    case grid, list
    var maxPixel: Int { self == .grid ? 300 : 90 }
}
