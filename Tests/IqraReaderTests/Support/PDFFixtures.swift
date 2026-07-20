import Foundation
import CoreGraphics
import CoreText

enum PDFFixtures {
    /// A PDF with `pageCount` pages; page i contains the text `texts[i]` (drawn) so search
    /// and text extraction have something to find. No outline (CGPDFContext can't add one).
    static func makePDF(pageCount: Int, texts: [String] = [], dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(UUID().uuidString + ".pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 600)
        let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        for i in 0..<pageCount {
            ctx.beginPDFPage(nil)
            let text = i < texts.count ? texts[i] : "Page \(i)"
            let attr = NSAttributedString(string: text,
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 24, nil)])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 40, y: 500)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
