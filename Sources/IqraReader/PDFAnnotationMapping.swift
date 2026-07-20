// Sources/IqraReader/PDFAnnotationMapping.swift
import Foundation
import PDFKit
#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformColor = UIColor
#endif

/// Pure conversions between PDFKit selections/annotations and our stored anchor
/// `{pageIndex, quads (page space), textQuote}`. No view, no I/O — fully unit-testable.
public enum PDFAnnotationMapping {
    /// Page-space rect → quad corners in Z order (UL, UR, LL, LR), page-space absolute.
    public static func quad(from r: CGRect) -> [Double] {
        [Double(r.minX), Double(r.maxY),   // UL
         Double(r.maxX), Double(r.maxY),   // UR
         Double(r.minX), Double(r.minY),   // LL
         Double(r.maxX), Double(r.minY)]   // LR
    }

    public static func rect(from quad: [Double]) -> CGRect {
        guard quad.count == 8 else { return .zero }
        let xs = [quad[0], quad[2], quad[4], quad[6]]
        let ys = [quad[1], quad[3], quad[5], quad[7]]
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func anchor(from selection: PDFSelection, in document: PDFDocument)
        -> (pageIndex: Int, quads: [[Double]], textQuote: String)? {
        let lines = selection.selectionsByLine()
        guard let page = (lines.first ?? selection).pages.first else { return nil }
        let quads = lines.map { quad(from: $0.bounds(for: page)) }.filter { $0.count == 8 }
        guard !quads.isEmpty else { return nil }
        return (document.index(for: page), quads, selection.string ?? "")
    }

    public static func highlightAnnotations(quads: [[Double]], colorHex: String) -> [PDFAnnotation] {
        let color = PlatformColor(hex: colorHex)
        return quads.map { q in
            let a = PDFAnnotation(bounds: rect(from: q), forType: .highlight, withProperties: nil)
            a.color = color
            return a
        }
    }
}

extension PlatformColor {
    convenience init(hex: String) {
        var v: UInt64 = 0; Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
