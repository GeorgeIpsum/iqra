import Foundation
import ZIPFoundation

/// Extracts a CBZ (zip of images) once into an evictable on-disk cache with a manifest of
/// naturally-sorted, zero-padded pages (spec: comic extraction is cached, not held in the
/// managed library — pages are lazily paged in at read time, not decoded from the zip repeatedly).
public enum ComicExtractor {
    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "heic", "avif"]

    /// True for real page images: excludes macOS zip cruft (`__MACOSX/`), dotfiles (incl.
    /// AppleDouble `._foo` sidecars), `ComicInfo.xml`, and any non-image extension.
    static func isImage(_ path: String) -> Bool {
        let base = (path as NSString).lastPathComponent
        guard !base.hasPrefix("."), !path.hasPrefix("__MACOSX/") else { return false }
        return imageExts.contains((path as NSString).pathExtension.lowercased())
    }

    /// Extract a CBZ's images (natural-sorted) into `cacheDir` as 0000.<ext>… + manifest.json.
    /// Returns the manifest. Idempotent-ish: always re-extracts into a freshly-cleared
    /// `cacheDir`, so a partial/stale extraction never masquerades as complete.
    @discardableResult
    public static func extractCBZ(cbzURL: URL, into cacheDir: URL) throws -> ComicManifest {
        let fm = FileManager.default
        try? fm.removeItem(at: cacheDir)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let archive = try Archive(url: cbzURL, accessMode: .read, pathEncoding: nil)
        let imageEntries = archive.filter { $0.type == .file && isImage($0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var pages: [ComicManifest.Page] = []
        for (i, entry) in imageEntries.enumerated() {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            let fileName = String(format: "%04d.%@", i, ext)
            let dest = cacheDir.appendingPathComponent(fileName)
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            try data.write(to: dest)
            pages.append(.init(index: i, fileName: fileName))
        }
        let manifest = ComicManifest(pageCount: pages.count, pages: pages, readingDirection: "ltr")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: cacheDir.appendingPathComponent("manifest.json"), options: .atomic)
        return manifest
    }

    /// Loads a previously-written manifest from `cacheDir`, or nil if absent/unreadable
    /// (e.g. the cache was evicted) — callers re-extract in that case.
    public static func loadManifest(from cacheDir: URL) -> ComicManifest? {
        guard let data = try? Data(contentsOf: cacheDir.appendingPathComponent("manifest.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(ComicManifest.self, from: data)
    }
}
