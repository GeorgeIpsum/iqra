import Foundation

public enum ContributorRole: String, Codable, Sendable {
    case author, translator, narrator, editor
}

public struct Contributor: Codable, Equatable, Sendable {
    public let name: String
    public let sortName: String
    public let role: ContributorRole
    public init(name: String, sortName: String, role: ContributorRole) {
        self.name = name; self.sortName = sortName; self.role = role
    }
}

public struct BookIdentifier: Codable, Equatable, Sendable {
    public let type: String   // open bag: "isbn", "asin", "uuid", ... never a fixed column (spec)
    public let value: String
    public init(type: String, value: String) { self.type = type; self.value = value }
}

public struct ExtractedMetadata: Codable, Equatable, Sendable {
    public let title: String
    public let titleSort: String
    public let language: String?
    public let publisher: String?
    public let bookDescription: String?
    public let contributors: [Contributor]
    public let identifiers: [BookIdentifier]

    public init(title: String, titleSort: String, language: String?, publisher: String?,
                bookDescription: String?, contributors: [Contributor], identifiers: [BookIdentifier]) {
        self.title = title; self.titleSort = titleSort; self.language = language
        self.publisher = publisher; self.bookDescription = bookDescription
        self.contributors = contributors; self.identifiers = identifiers
    }
}

/// Stored sort key, computed once at import (spec: "never collate in queries").
/// English-only article stripping in M1; other languages pass through.
public func makeTitleSort(_ title: String, language: String?) -> String {
    let lang = language?.lowercased().prefix(2) ?? "en"
    guard lang == "en" else { return title }
    for article in ["The ", "A ", "An "] where title.hasPrefix(article) {
        let rest = String(title.dropFirst(article.count))
        return "\(rest), \(article.trimmingCharacters(in: .whitespaces))"
    }
    return title
}
