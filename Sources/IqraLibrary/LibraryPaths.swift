import Foundation
import IqraCore

/// All knowledge of the managed-library filesystem layout. Placeholder body grows in Task 8.
public struct LibraryPaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
}
