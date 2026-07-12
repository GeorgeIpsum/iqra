import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

enum Fixtures {
    /// A 4x4 red JPEG rendered with CoreGraphics — no binary fixture files.
    static func tinyJPEG() -> Data {
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// A 600x400 red JPEG — large enough that thumbnail max-pixel downscaling is observable
    /// (tinyJPEG's 4x4 is already smaller than every thumbnail cap, so it can't catch a
    /// copy-the-original bug).
    static func largeJPEG() -> Data {
        let width = 600, height = 400
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func makeEPUB(title: String, author: String, isbn: String?, language: String = "en",
                         coverJPEG: Data? = nil, encrypted: Bool = false, encryptionXML: String? = nil,
                         dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".epub")
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        func add(_ name: String, _ text: String) throws {
            let data = Data(text.utf8)
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count),
                                 provider: { p, s in data.subdata(in: Int(p)..<Int(p) + s) })
        }
        try add("mimetype", "application/epub+zip")
        try add("META-INF/container.xml", """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """)
        if let encryptionXML {
            try add("META-INF/encryption.xml", encryptionXML)
        } else if encrypted {
            try add("META-INF/encryption.xml", """
                <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
                    <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
                  </EncryptedData>
                </encryption>
                """)
        }
        let coverManifest = coverJPEG != nil
            ? #"<item id="cover-image" href="cover.jpg" media-type="image/jpeg"/>"# : ""
        let coverMeta = coverJPEG != nil ? #"<meta name="cover" content="cover-image"/>"# : ""
        let isbnXML = isbn.map { #"<dc:identifier opf:scheme="ISBN">\#($0)</dc:identifier>"# } ?? ""
        try add("OEBPS/content.opf", """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(title)</dc:title>
                <dc:creator>\(author)</dc:creator>
                <dc:language>\(language)</dc:language>
                <dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier>
                \(isbnXML)
                <dc:description>Fixture description.</dc:description>
                \(coverMeta)
              </metadata>
              <manifest>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                \(coverManifest)
              </manifest>
              <spine><itemref idref="ch1"/></spine>
            </package>
            """)
        try add("OEBPS/ch1.xhtml", "<html><body><p>Hello.</p></body></html>")
        if let coverJPEG {
            try archive.addEntry(with: "OEBPS/cover.jpg", type: .file,
                                 uncompressedSize: Int64(coverJPEG.count),
                                 provider: { p, s in coverJPEG.subdata(in: Int(p)..<Int(p) + s) })
        }
        return url
    }

    static func makePDF(title: String?, author: String?, password: String? = nil, dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        if let author { info[kCGPDFContextAuthor] = author }
        if let password {
            info[kCGPDFContextOwnerPassword] = password
            info[kCGPDFContextUserPassword] = password
        }
        let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 160, height: 260))
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }
}
