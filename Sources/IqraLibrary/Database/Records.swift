import Foundation
import GRDB

public struct BookRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "book"
    public var id: String
    public var title: String
    public var titleSort: String
    public var bookDescription: String?
    public var publisher: String?
    public var pubDate: String?
    public var language: String?
    public var seriesId: String?
    public var seriesIndex: Double?
    public var wantToRead: Bool
    public var isFinished: Bool
    public var dateFinished: Date?
    public var lastOpenedAt: Date?
    public var addedAt: Date
    public var applySeq: Int64
    public var deleted: Bool
}

public struct FormatRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "format"
    public var id: String
    public var bookId: String
    public var formatType: String
    public var originalFileName: String
    public var byteSize: Int64
    public var contentHash: String
    public var addedAt: Date
    public var applySeq: Int64
    public var deleted: Bool
}

public struct ImportItemRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "import_item"
    public var id: String
    public var sourceBookmark: Data?
    public var sourceDisplayPath: String
    public var status: String        // pending/importing/quarantined/failed/done
    public var rejection: String?    // ImportRejection rawValue
    public var message: String?
    public var attemptCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var bookId: String?
}

public struct AnnotationRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    public static let databaseTableName = "annotation"
    public var id: String
    public var bookId: String
    public var formatId: String
    public var kind: String
    public var locator: String
    public var color: String?
    public var noteText: String?
    public var createdAt: Date
    public var modifiedAt: Date
    public var applySeq: Int64
    public var deleted: Bool
}
