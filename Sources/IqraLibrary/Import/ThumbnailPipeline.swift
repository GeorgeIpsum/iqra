import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ThumbnailResult: Equatable, Sendable {
    case written
    case skippedNoCover
    case failedInvalidImage
}

public enum ThumbnailPipeline {
    /// Eager thumbnails at import time, never at scroll time (spec).
    ///
    /// Layout knowledge (cover.jpg location, thumbnails directory) lives entirely in
    /// `LibraryPaths`/`LibraryPaths.Caches` — this pipeline only asks for destinations.
    @discardableResult
    public static func process(coverData: Data?, bookID: UUID, paths: LibraryPaths,
                               caches: LibraryPaths.Caches) throws -> ThumbnailResult {
        guard let coverData else { return .skippedNoCover }

        guard let source = CGImageSourceCreateWithData(coverData as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return .failedInvalidImage }

        try coverData.write(to: paths.cover(bookID: bookID), options: .atomic)

        let thumbsDir = caches.thumbnail(bookID: bookID, size: .grid).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
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
        return .written
    }
}
