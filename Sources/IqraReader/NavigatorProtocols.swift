// Sources/IqraReader/NavigatorProtocols.swift
import Foundation

/// Base navigator surface (spec: protocol composition — capability protocols like
/// TextSelectable/RangeAnnotatable arrive with their features in M3/M4).
@MainActor
public protocol NavigatorDelegate: AnyObject {
    func navigatorDidLoad(title: String?, toc: [TOCItem])
    func navigator(didRelocate locator: Locator)
    func navigator(didFail message: String)
}

public struct TOCItem: Codable, Equatable, Sendable {
    public let label: String
    public let href: String?
    public let subitems: [TOCItem]?
    public init(label: String, href: String?, subitems: [TOCItem]?) {
        self.label = label; self.href = href; self.subitems = subitems
    }
}
