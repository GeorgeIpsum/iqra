import Foundation
import WebKit

public enum BookScheme {
    public static let scheme = "iqra-book"
    public static func pageURL(bookID: UUID) -> URL {
        URL(string: "\(scheme)://\(bookID.uuidString.lowercased())/index.html")!
    }
}

/// Maps iqra-book:// URLs to data. One instance serves exactly one book (unique host per
/// book = per-book origin isolation, spec "Security"). Pure and unit-testable — the
/// WKURLSchemeHandler below is a thin adapter.
public struct BookResourceResolver: Sendable {
    public struct Response {
        public let data: Data
        public let mimeType: String
    }

    /// Reference CSP from upstream foliate-js reader.html, tightened: no remote anything;
    /// blob:/data: allowances are what the in-page zip → blob-URL pipeline needs.
    public static let contentSecurityPolicy = [
        "default-src 'self' blob:",
        "script-src 'self'",
        "style-src 'self' blob: 'unsafe-inline'",
        "img-src 'self' blob: data:",
        "font-src 'self' blob: data:",
        "connect-src 'self' blob: data:",
        "frame-src blob: data:",
        "object-src blob: data:",
        "form-action 'none'",
    ].joined(separator: "; ")

    let bookID: UUID
    let bookFileURL: URL
    let bundle: Bundle

    public init(bookID: UUID, bookFileURL: URL, bundle: Bundle? = nil) {
        self.bookID = bookID; self.bookFileURL = bookFileURL
        self.bundle = bundle ?? .module
    }

    public func response(for url: URL) -> Response? {
        guard url.scheme == BookScheme.scheme,
              url.host()?.lowercased() == bookID.uuidString.lowercased() else { return nil }
        // Normalize and forbid traversal: no component may be "..".
        let components = url.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        let path = components.joined(separator: "/")

        switch path {
        case "book.epub":
            guard let data = try? Data(contentsOf: bookFileURL) else { return nil }
            return Response(data: data, mimeType: "application/epub+zip")
        case "index.html":
            return bundled("ReaderAssets/reader.html", mime: "text/html")
        case "bridge.js":
            return bundled("ReaderAssets/bridge.js", mime: "text/javascript")
        default:
            guard path.hasPrefix("vendor/foliate-js/") else { return nil }
            let mime = path.hasSuffix(".js") ? "text/javascript" : "application/octet-stream"
            return bundled("Vendor/foliate-js/" + path.dropFirst("vendor/foliate-js/".count),
                           mime: mime)
        }
    }

    private func bundled(_ relativePath: String, mime: String) -> Response? {
        // .copy resources (Vendor/, ReaderAssets/) land as top-level children of the bundle's
        // *resource directory* — bundle.resourceURL, which NSBundle already resolves correctly
        // per platform bundle layout: the flat layout SwiftPM/iOS use (resourceURL == the
        // bundle's own root) and the Contents/Resources-wrapped layout Xcode uses for native
        // macOS app targets (resourceURL == .../Contents/Resources) both verified empirically.
        //
        // Do NOT special-case this by going "up a level" from resourceURL, and do NOT use
        // bundle.bundleURL instead: an earlier version of this code did the former to
        // compensate for NSBundle's legacy-bundle sniffing, which special-cases a top-level
        // child literally named "resources" (any case) as a classic Mac "Resources/" folder
        // and redirects a flat bundle's resourceURL to point inside it. That same sniffing is
        // what made codesign misidentify the bundle as an old-style bundle lacking the expected
        // executable, failing ad-hoc signing on iOS/iOS Simulator with "bundle format
        // unrecognized, invalid, or unsuitable" (reproduced empirically) — hence the resource
        // directory is named ReaderAssets, not Resources, and resourceURL is used unmodified.
        guard let resourceURL = bundle.resourceURL else { return nil }
        let fileURL = resourceURL.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return Response(data: data, mimeType: mime)
    }
}

public final class BookResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    let resolver: BookResourceResolver
    public init(resolver: BookResourceResolver) { self.resolver = resolver }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let response = resolver.response(for: url) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = [
            "Content-Type": response.mimeType,
            "Content-Length": String(response.data.count),
            "Content-Security-Policy": BookResourceResolver.contentSecurityPolicy,
        ]
        let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: headers)!
        task.didReceive(http)
        task.didReceive(response.data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Whole responses are delivered synchronously above; nothing to cancel.
    }
}
