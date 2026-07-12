import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ThumbnailPipeline {
    /// Eager thumbnails at import time, never at scroll time (spec).
    public static func process(coverData: Data?, bookDir: URL, bookID: UUID,
                               caches: LibraryPaths.Caches) throws {
        guard let coverData else { return }
        try coverData.write(to: bookDir.appendingPathComponent("cover.jpg"), options: .atomic)

        let thumbsDir = caches.root.appendingPathComponent("thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        guard let source = CGImageSourceCreateWithData(coverData as CFData, nil) else { return }
        for size in ThumbnailSize.allCases {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: size.maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { continue }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                out, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { continue }
            try (out as Data).write(to: caches.thumbnail(bookID: bookID, size: size), options: .atomic)
        }
    }
}
