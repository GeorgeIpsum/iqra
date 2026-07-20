import Foundation
import IqraCore
import ZIPFoundation

/// Native comic metadata: ComicInfo.xml `<Title>` (fallback: filename) + first naturally-sorted
/// image as cover. Lives in IqraLibrary — deliberately does NOT import IqraReader; this is a
/// small self-contained container walk mirroring EPUBMetadataExtractor/PDFMetadataExtractor,
/// not a call into ComicExtractor (full page extraction happens lazily at first open, Task 8).
public enum ComicMetadataExtractor {
    public static func extract(fileURL: URL, formatType: FormatType) -> ExtractionResult {
        guard formatType == .cbz,   // cbr stays quarantined this milestone
              let archive = try? Archive(url: fileURL, accessMode: .read, pathEncoding: nil) else {
            return .rejected(.unsupportedFormat)
        }
        let images = archive.filter { $0.type == .file && isImage($0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !images.isEmpty else { return .rejected(.corruptContainer) }

        var title = fileURL.deletingPathExtension().lastPathComponent
        if let ci = archive["ComicInfo.xml"] {
            var data = Data()
            _ = try? archive.extract(ci) { data.append($0) }
            if let parsedTitle = ComicInfoParser.title(data) { title = parsedTitle }
        }
        var cover = Data()
        _ = try? archive.extract(images[0]) { cover.append($0) }
        let metadata = ExtractedMetadata(
            title: title, titleSort: makeTitleSort(title, language: nil),
            language: nil, publisher: nil, bookDescription: nil,
            contributors: [], identifiers: [])
        return .extracted(metadata, coverData: cover.isEmpty ? nil : cover)
    }

    static func isImage(_ path: String) -> Bool {
        let base = (path as NSString).lastPathComponent
        guard !base.hasPrefix("."), !path.hasPrefix("__MACOSX/") else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "heic", "avif"].contains(ext)
    }
}

/// Parses ComicInfo.xml (ComicRack schema) for a `<Title>` element. Best-effort: any parse
/// failure or empty title falls back to the caller's default (the filename).
enum ComicInfoParser {
    static func title(_ data: Data) -> String? {
        final class Delegate: NSObject, XMLParserDelegate {
            var inTitle = false
            var title: String?
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                inTitle = (name == "Title")
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inTitle { title = (title ?? "") + string }
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                        qualifiedName: String?) {
                if name == "Title" { inTitle = false }
            }
        }
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        parser.parse()
        let trimmed = delegate.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
