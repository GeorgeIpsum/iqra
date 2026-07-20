// Sources/IqraReader/NavigatorProtocols.swift
import Foundation

/// Base navigator surface (spec: protocol composition). Every format's navigator conforms;
/// capability protocols below are adopted only by navigators that support them, and the UI
/// drives features by conformance check — so it can never offer text highlighting on a comic.
@MainActor public protocol Navigator: AnyObject {
    var delegate: NavigatorDelegate? { get set }
    func start()
    func goTo(locator: Locator)
    func next()
    func prev()
}

@MainActor public protocol AppearanceConfigurable {
    func apply(settings: ReaderSettings)
}

/// Text can be selected; selections are reported via `NavigatorDelegate.navigator(didChangeSelection:)`.
@MainActor public protocol TextSelectable: AnyObject {
    func deselect()
}

/// Range highlights/notes can be drawn; taps are reported via `NavigatorDelegate.navigator(didTapAnnotation:)`.
@MainActor public protocol RangeAnnotatable: AnyObject {
    func addAnnotation(_ annotation: Annotation)
    func removeAnnotation(_ annotation: Annotation)
}

/// Full-text search within the open document; hits via `NavigatorDelegate`.
@MainActor public protocol Searchable: AnyObject {
    func search(query: String)
    func clearSearch()
}

@MainActor public protocol NavigatorDelegate: AnyObject {
    func navigatorDidLoad(title: String?, toc: [TOCItem])
    func navigator(didRelocate locator: Locator)
    func navigator(didFail message: String)
    func navigator(didChangeSelection selection: SelectionInfo?)
    func navigator(didTapAnnotation id: UUID)
    func navigator(didFindSearchHit hit: SearchHit)
    func navigatorDidFinishSearch()
}

public extension NavigatorDelegate {
    func navigator(didChangeSelection selection: SelectionInfo?) {}
    func navigator(didTapAnnotation id: UUID) {}
    func navigator(didFindSearchHit hit: SearchHit) {}
    func navigatorDidFinishSearch() {}
}

public struct TOCItem: Codable, Equatable, Sendable {
    public let label: String
    public let href: String?
    public let subitems: [TOCItem]?
    public init(label: String, href: String?, subitems: [TOCItem]?) {
        self.label = label; self.href = href; self.subitems = subitems
    }
}
