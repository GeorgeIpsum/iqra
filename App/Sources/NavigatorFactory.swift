// App/Sources/NavigatorFactory.swift
import Foundation
import IqraCore
import IqraReader

/// Picks the right navigator implementation for a format (spec: "The other engines" — the app
/// is the composition point, `IqraReader` never chooses on the format's behalf). Returns nil for
/// formats with no reader yet, so `ReaderViewModel.init?` fails closed rather than opening a
/// half-working reader.
enum NavigatorFactory {
    @MainActor static func make(formatType: FormatType, bookID: UUID, formatURL: URL,
                                initialLocator: Locator?, settings: ReaderSettings) -> (any Navigator)? {
        switch formatType {
        case .epub, .mobi:   // MOBI renders through the same foliate engine (M5); EPUB today
            return EPUBNavigator(bookID: bookID, bookFileURL: formatURL,
                                 initialLocator: initialLocator, settings: settings)
        // .pdf and .cbz cases are added by Tasks 6 and 9.
        default:
            return nil
        }
    }
}
