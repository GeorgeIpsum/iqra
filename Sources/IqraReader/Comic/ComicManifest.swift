import Foundation

/// The on-disk description of an extracted comic's pages, cached alongside the extracted
/// page images (spec: CBZ extraction is cached and evictable, keyed by manifest.json).
public struct ComicManifest: Codable, Equatable, Sendable {
    public struct Page: Codable, Equatable, Sendable {
        public let index: Int
        public let fileName: String
        public init(index: Int, fileName: String) {
            self.index = index
            self.fileName = fileName
        }
    }
    public var pageCount: Int
    public var pages: [Page]
    public var readingDirection: String   // "ltr" | "rtl"

    public init(pageCount: Int, pages: [Page], readingDirection: String) {
        self.pageCount = pageCount
        self.pages = pages
        self.readingDirection = readingDirection
    }
}
