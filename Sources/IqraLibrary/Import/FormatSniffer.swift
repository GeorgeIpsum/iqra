import Foundation
import IqraCore
import ZIPFoundation

public enum SniffResult: Equatable, Sendable {
    case recognized(FormatType)
    case unrecognized
}

public enum FormatSniffer {
    public static func sniff(fileURL: URL) throws -> SniffResult {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 68) ?? Data()

        if head.starts(with: Data("%PDF".utf8)) { return .recognized(.pdf) }
        if head.starts(with: Data("Rar!".utf8)) { return .recognized(.cbr) }
        if head.count >= 68, head[60..<68] == Data("BOOKMOBI".utf8) { return .recognized(.mobi) }
        if head.starts(with: Data([0x50, 0x4B, 0x03, 0x04])) {
            // zip: EPUB iff the mimetype entry says so; otherwise treat as comic archive
            guard let archive = try? Archive(url: fileURL, accessMode: .read, pathEncoding: nil) else { return .unrecognized }
            if let entry = archive["mimetype"] {
                var content = Data()
                _ = try? archive.extract(entry) { content.append($0) }
                if String(decoding: content, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" {
                    return .recognized(.epub)
                }
            }
            return .recognized(.cbz)
        }
        return .unrecognized
    }
}
