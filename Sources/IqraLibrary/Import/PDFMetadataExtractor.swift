import Foundation
import IqraCore
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum PDFMetadataExtractor {
    public static func extract(fileURL: URL) -> ExtractionResult {
        guard let doc = PDFDocument(url: fileURL), doc.pageCount > 0 else {
            return .rejected(.corruptContainer)
        }
        if doc.isEncrypted { return .rejected(.drmProtected) }

        let attrs = doc.documentAttributes ?? [:]
        let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? fileURL.deletingPathExtension().lastPathComponent
        let author = (attrs[PDFDocumentAttribute.authorAttribute] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        var coverData: Data? = nil
        if let page = doc.page(at: 0) {
            let bounds = page.bounds(for: .mediaBox)
            let scale = 400 / max(bounds.width, 1)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
                page.draw(with: .mediaBox, to: ctx)
                if let image = ctx.makeImage() {
                    let out = NSMutableData()
                    if let dest = CGImageDestinationCreateWithData(
                        out, UTType.jpeg.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, image, nil)
                        if CGImageDestinationFinalize(dest) { coverData = out as Data }
                    }
                }
            }
        }
        let metadata = ExtractedMetadata(
            title: title, titleSort: makeTitleSort(title, language: nil),
            language: nil, publisher: nil, bookDescription: nil,
            contributors: author.map {
                [Contributor(name: $0, sortName: EPUBMetadataExtractor.makeAuthorSort($0), role: .author)]
            } ?? [],
            identifiers: [])
        return .extracted(metadata, coverData: coverData)
    }
}
