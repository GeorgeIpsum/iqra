import Foundation
import IqraCore
import ZIPFoundation

public enum ExtractionResult: Equatable, Sendable {
    case extracted(ExtractedMetadata, coverData: Data?)
    case rejected(ImportRejection)
}

public enum EPUBMetadataExtractor {
    public static func extract(fileURL: URL) -> ExtractionResult {
        guard let archive = try? Archive(url: fileURL, accessMode: .read, pathEncoding: nil) else {
            return .rejected(.corruptContainer)
        }
        func read(_ path: String) -> Data? {
            guard let entry = archive[path] else { return nil }
            var data = Data()
            guard (try? archive.extract(entry) { data.append($0) }) != nil else { return nil }
            return data
        }
        // DRM check (spec: encryption.xml beyond font obfuscation → quarantine).
        if let enc = read("META-INF/encryption.xml") {
            let text = String(decoding: enc, as: UTF8.self)
            let fontOnly = text.contains("http://www.idpf.org/2008/embedding")
                || text.contains("http://ns.adobe.com/pdf/enc#RC")
            if !fontOnly { return .rejected(.drmProtected) }
        }
        guard let containerData = read("META-INF/container.xml"),
              let opfPath = OPFPathParser.parse(containerData),
              let opfData = read(opfPath) else {
            return .rejected(.corruptContainer)
        }
        let opf = OPFParser()
        guard let parsed = opf.parse(opfData) else { return .rejected(.corruptContainer) }

        var coverData: Data? = nil
        if let coverHref = parsed.coverHref {
            let opfDir = (opfPath as NSString).deletingLastPathComponent
            let coverPath = opfDir.isEmpty ? coverHref : opfDir + "/" + coverHref
            coverData = read(coverPath)
        }
        let metadata = ExtractedMetadata(
            title: parsed.title, titleSort: makeTitleSort(parsed.title, language: parsed.language),
            language: parsed.language, publisher: parsed.publisher,
            bookDescription: parsed.description,
            contributors: parsed.creators.map {
                Contributor(name: $0, sortName: makeAuthorSort($0), role: .author)
            },
            identifiers: parsed.identifiers)
        return .extracted(metadata, coverData: coverData)
    }

    /// "Ursula K. Le Guin" → "Le Guin, Ursula K." — naive last-token inversion, calibre's default method.
    static func makeAuthorSort(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard parts.count > 1, let last = parts.last else { return name }
        return "\(last), \(parts.dropLast().joined(separator: " "))"
    }
}

/// Finds the OPF rootfile path in container.xml.
enum OPFPathParser {
    static func parse(_ data: Data) -> String? {
        final class Delegate: NSObject, XMLParserDelegate {
            var path: String?
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName: String?, attributes: [String: String] = [:]) {
                if name == "rootfile", path == nil { path = attributes["full-path"] }
            }
        }
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        parser.parse()
        return delegate.path
    }
}

/// Minimal OPF (package document) metadata parser.
final class OPFParser: NSObject, XMLParserDelegate {
    struct Result {
        var title = ""
        var creators: [String] = []
        var language: String?
        var publisher: String?
        var description: String?
        var identifiers: [BookIdentifier] = []
        var coverHref: String?
    }
    private var result = Result()
    private var currentElement = ""
    private var currentText = ""
    private var currentScheme: String?
    private var coverImageID: String?
    private var manifestHrefByID: [String: String] = [:]

    func parse(_ data: Data) -> Result? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        guard parser.parse(), !result.title.isEmpty else { return nil }
        if let id = coverImageID { result.coverHref = manifestHrefByID[id] }
        return result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = name
        currentText = ""
        currentScheme = attributes["opf:scheme"] ?? attributes["scheme"]
        if name == "meta", attributes["name"] == "cover" { coverImageID = attributes["content"] }
        if name == "item", let id = attributes["id"], let href = attributes["href"] {
            manifestHrefByID[id] = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch name {
        case "title" where result.title.isEmpty: result.title = text
        case "creator": result.creators.append(text)
        case "language" where result.language == nil: result.language = text
        case "publisher": result.publisher = text
        case "description": result.description = text
        case "identifier":
            let scheme = (currentScheme ?? "").lowercased()
            if scheme == "isbn" {
                result.identifiers.append(BookIdentifier(type: "isbn", value: text))
            } else if text.lowercased().hasPrefix("urn:isbn:") {
                result.identifiers.append(BookIdentifier(type: "isbn", value: String(text.dropFirst(9))))
            } else {
                result.identifiers.append(BookIdentifier(type: "uuid", value: text))
            }
        default: break
        }
        currentText = ""
    }
}
