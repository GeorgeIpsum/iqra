// App/Sources/NavigatorFactory.swift
import Foundation
import IqraCore
import IqraLibrary
import IqraReader

/// Picks the right navigator implementation for a format (spec: "The other engines" — the app
/// is the composition point, `IqraReader` never chooses on the format's behalf). Returns nil for
/// formats with no reader yet, so `ReaderViewModel.init?` fails closed rather than opening a
/// half-working reader.
enum NavigatorFactory {
    @MainActor static func make(formatType: FormatType, bookID: UUID, formatID: UUID, formatURL: URL,
                                initialLocator: Locator?, settings: ReaderSettings,
                                caches: LibraryPaths.Caches) -> (any Navigator)? {
        switch formatType {
        case .epub, .mobi:   // MOBI renders through the same foliate engine (M5); EPUB today
            return EPUBNavigator(bookID: bookID, bookFileURL: formatURL,
                                 initialLocator: initialLocator, settings: settings)
        case .pdf:
            return PDFNavigator(bookID: bookID, bookFileURL: formatURL, initialLocator: initialLocator)
        case .cbz:
            return ComicNavigator(bookID: bookID, comicFileURL: formatURL,
                                  cacheDir: caches.comicPagesDir(formatID: formatID), initialLocator: initialLocator)
        default:
            return nil
        }
    }
}
