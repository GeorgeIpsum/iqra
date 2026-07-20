// App/Sources/PDFReaderView.swift
import SwiftUI
import PDFKit
import IqraReader

/// Hosts a `PDFNavigator`'s `PDFView` plus a horizontal `PDFThumbnailView` scrubber beneath it.
struct PDFReaderView: View {
    let navigator: PDFNavigator
    var body: some View {
        VStack(spacing: 0) {
            PDFViewContainer(pdfView: navigator.pdfView).ignoresSafeArea(edges: .bottom)
            PDFThumbnailContainer(pdfView: navigator.pdfView).frame(height: 64)
        }
    }
}

private struct PDFViewContainer {
    let pdfView: PDFView
}
private struct PDFThumbnailContainer {
    let pdfView: PDFView
    func makeThumb() -> PDFThumbnailView {
        let t = PDFThumbnailView(); t.pdfView = pdfView
        t.thumbnailSize = CGSize(width: 40, height: 56)
        #if os(iOS)
        t.layoutMode = .horizontal
        #else
        // macOS PDFThumbnailView has no `layoutMode` — it flows a grid within its bounds.
        // Unlimited columns + the 64pt-tall strip this view is constrained to (one row of
        // 56pt-tall thumbnails) makes it wrap as a single horizontal row, same effect as iOS.
        t.maximumNumberOfColumns = 0
        #endif
        return t
    }
}

#if os(macOS)
extension PDFViewContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ v: PDFView, context: Context) {}
}
extension PDFThumbnailContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFThumbnailView { makeThumb() }
    func updateNSView(_ v: PDFThumbnailView, context: Context) {}
}
#else
extension PDFViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { pdfView }
    func updateUIView(_ v: PDFView, context: Context) {}
}
extension PDFThumbnailContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFThumbnailView { makeThumb() }
    func updateUIView(_ v: PDFThumbnailView, context: Context) {}
}
#endif
