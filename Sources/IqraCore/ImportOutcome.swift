import Foundation

/// Why the classify stage refused a file (spec: quarantine with user-facing states).
public enum ImportRejection: String, Codable, Sendable {
    case drmProtected, unsupportedFormat, corruptContainer
}

/// Result of the dedupe ladder (spec "Import pipeline" stage 5).
public enum DedupeDecision: Equatable, Sendable {
    case newBook
    case hydrate(formatID: UUID)            // hash matches a Format whose binary is missing locally
    case skipExactDuplicate(formatID: UUID) // hash matches and binary present
    case askIdentifierMatch(existingBookID: UUID) // surfaced to the user, never silent
}
