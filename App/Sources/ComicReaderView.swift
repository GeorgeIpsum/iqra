// App/Sources/ComicReaderView.swift
import SwiftUI
import ImageIO
import IqraReader

struct ComicReaderView: View {
    @Bindable var navigator: ComicNavigator

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(navigator.pages) { page in
                    ComicPageCell(url: page.url)
                        .containerRelativeFrame(.horizontal)
                        .id(page.index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: Binding(
            get: { navigator.currentIndex },
            set: { if let i = $0 { navigator.currentIndex = i } }))
        .environment(\.layoutDirection, navigator.readingDirection == "rtl" ? .rightToLeft : .leftToRight)
        .background(.black)
        .ignoresSafeArea()
    }
}

/// Decodes its page lazily (downsampled, off-main) and releases on disappear — so only the
/// visible ±1 pages are ever held decoded, regardless of comic length.
private struct ComicPageCell: View {
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let cg = image {
                Image(decorative: cg, scale: 1, orientation: .up).resizable().scaledToFit()
            } else { Color.black }
        }
        .task(id: url) {
            let decoded = await Task.detached { Self.downsample(url, maxPixel: 2048) }.value
            guard !Task.isCancelled else { return }
            image = decoded
        }
        .onDisappear { image = nil }
    }
    nonisolated static func downsample(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
