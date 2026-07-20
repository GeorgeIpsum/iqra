// Sources/IqraReader/EPUBNavigator.swift
import Foundation
import WebKit

/// Owns one WKWebView rendering one EPUB via foliate-js. All communication with page JS
/// goes through the single `iqra` message channel; all durable state is the caller's
/// responsibility (persist on every relocate — the DB, not the web view, is the source
/// of truth; spec "Process-kill recovery contract").
@MainActor
public final class EPUBNavigator: NSObject, Navigator, AppearanceConfigurable, TextSelectable,
                                   RangeAnnotatable, Searchable {
    public let webView: WKWebView
    public weak var delegate: NavigatorDelegate?
    public private(set) var lastLocator: Locator?

    private let bookID: UUID
    private var settings: ReaderSettings
    private let initialLocator: Locator?

    public init(bookID: UUID, bookFileURL: URL, initialLocator: Locator?,
                settings: ReaderSettings) {
        self.bookID = bookID
        self.settings = settings
        self.initialLocator = initialLocator

        let resolver = BookResourceResolver(bookID: bookID, bookFileURL: bookFileURL)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BookResourceSchemeHandler(resolver: resolver),
                                   forURLScheme: BookScheme.scheme)
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(MessageProxy(self), name: "iqra")
        webView.navigationDelegate = self
        #if os(iOS)
        webView.scrollView.bounces = false
        webView.isOpaque = false
        #endif
    }

    /// Compiles the network-blocking rule list, then loads the reader page.
    public func start() {
        // Block every load except our custom scheme (spec: WKContentRuleList blocks all
        // remote loads; the CSP is the second layer).
        let rules = """
        [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
         {"trigger": {"url-filter": "^iqra-book://.*"}, "action": {"type": "ignore-previous-rules"}},
         {"trigger": {"url-filter": "^blob:.*"}, "action": {"type": "ignore-previous-rules"}},
         {"trigger": {"url-filter": "^data:.*"}, "action": {"type": "ignore-previous-rules"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "iqra-book-blocklist", encodedContentRuleList: rules) { [weak self] list, error in
            Task { @MainActor in
                guard let self else { return }
                if let list {
                    self.webView.configuration.userContentController.add(list)
                } else if let error {
                    // Rule-list failure must not brick reading — CSP still blocks remote
                    // loads. Surface it so it is never silent.
                    self.delegate?.navigator(didFail: "content blocker unavailable: \(error)")
                }
                self.webView.load(URLRequest(url: BookScheme.pageURL(bookID: self.bookID)))
            }
        }
    }

    public func goTo(cfi: String) { call("iqra.goTo(\(jsString(cfi)))") }
    public func goTo(fraction: Double) { call("iqra.goTo({fraction: \(fraction)})") }
    public func goTo(locator: Locator) {
        if let cfi = locator.cfi { goTo(cfi: cfi) } else { goTo(fraction: locator.totalProgression) }
    }
    public func next() { call("iqra.next()") }
    public func prev() { call("iqra.prev()") }

    public func addAnnotation(_ annotation: Annotation) {
        let payload: [String: Any] = [
            "cfi": annotation.locator.cfi ?? "",
            "color": annotation.color?.cssColor ?? NSNull(),
            "kind": annotation.kind.rawValue,
            "id": annotation.id.uuidString,
        ]
        guard annotation.locator.cfi != nil,
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        call("iqra.addAnnotation(\(String(decoding: data, as: UTF8.self)))")
    }

    public func removeAnnotation(_ annotation: Annotation) {
        guard let cfi = annotation.locator.cfi,
              let data = try? JSONSerialization.data(withJSONObject: ["cfi": cfi]) else { return }
        call("iqra.removeAnnotation(\(String(decoding: data, as: UTF8.self)))")
    }

    public func deselect() { call("iqra.deselect()") }

    public func search(query: String) {
        let opts: [String: Any] = ["query": query]
        guard !query.isEmpty, let data = try? JSONSerialization.data(withJSONObject: opts) else { return }
        call("iqra.search(\(String(decoding: data, as: UTF8.self)))")
    }
    public func clearSearch() { call("iqra.clearSearch()") }

    public func apply(settings: ReaderSettings) {
        self.settings = settings
        if let json = try? String(decoding: JSONEncoder().encode(settings), as: UTF8.self) {
            call("iqra.setAppearance(\(json))")
        }
    }

    // MARK: - JS plumbing

    private func call(_ js: String) {
        webView.evaluateJavaScript(js) { _, error in
            if error != nil { /* page not ready yet; commands re-issue on ready/reload */ }
        }
    }

    private func jsString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode([s])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast()) // "…" JSON-escaped
    }

    fileprivate func handle(message body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            var config: [String: Any] = [:]
            if let data = try? JSONEncoder().encode(settings),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                config["settings"] = obj
            }
            // Prefer lastLocator: after a content-process recovery reload mid-session,
            // it holds the most recent relocate, while initialLocator is frozen at
            // construction time. Only fall back to initialLocator on the very first
            // "ready" (before any relocate has happened, lastLocator is still nil).
            if let cfi = lastLocator?.cfi ?? initialLocator?.cfi {
                config["lastCFI"] = cfi
            }
            if let data = try? JSONSerialization.data(withJSONObject: config) {
                call("iqra.start(\(String(decoding: data, as: UTF8.self)))")
            }
        case "loaded":
            let title = dict["title"] as? String
            let toc = (try? JSONSerialization.data(withJSONObject: dict["toc"] ?? []))
                .flatMap { try? JSONDecoder().decode([TOCItem].self, from: $0) } ?? []
            delegate?.navigatorDidLoad(title: title, toc: toc)
        case "relocate":
            // Defense in depth: the renderer (bridge.js) already guards against non-finite
            // values, but a NaN/Infinity here would fail JSON encoding and poison the
            // persisted high-water mark, so never trust the message payload blindly.
            let totalProgression = dict["totalProgression"] as? Double ?? 0
            let locator = Locator(
                spineIndex: dict["spineIndex"] as? Int ?? 0,
                spineHref: dict["spineHref"] as? String,
                cfi: dict["cfi"] as? String,
                progressionInChapter: dict["progressionInChapter"] as? Double,
                totalProgression: totalProgression.isFinite ? totalProgression : 0,
                tocLabel: dict["tocLabel"] as? String)
            lastLocator = locator
            delegate?.navigator(didRelocate: locator)
        case "error":
            delegate?.navigator(didFail: dict["message"] as? String ?? "unknown reader error")
        case "selected":
            guard let text = dict["text"] as? String, let cfi = dict["cfi"] as? String,
                  let rect = dict["rect"] as? [String: Any] else { return }
            let selRect = SelectionRect(x: rect["x"] as? Double ?? 0, y: rect["y"] as? Double ?? 0,
                                        width: rect["width"] as? Double ?? 0, height: rect["height"] as? Double ?? 0)
            var context: TextContext?
            if let tc = dict["textContext"] as? [String: Any] {
                context = TextContext(before: tc["before"] as? String ?? "",
                                      highlight: tc["highlight"] as? String ?? text,
                                      after: tc["after"] as? String ?? "")
            }
            let progression = dict["totalProgression"] as? Double ?? 0
            delegate?.navigator(didChangeSelection: SelectionInfo(
                text: text, cfi: cfi, rect: selRect, spineIndex: dict["spineIndex"] as? Int ?? 0,
                totalProgression: progression.isFinite ? progression : 0, textContext: context))
        case "selectionCleared":
            delegate?.navigator(didChangeSelection: nil)
        case "annotationTapped":
            guard let idString = dict["id"] as? String, let id = UUID(uuidString: idString) else { return }
            delegate?.navigator(didTapAnnotation: id)
        case "searchHit":
            guard let cfi = dict["cfi"] as? String else { return }
            let ex = dict["excerpt"] as? [String: Any]
            delegate?.navigator(didFindSearchHit: SearchHit(
                cfi: cfi,
                excerptPre: ex?["pre"] as? String ?? "",
                excerptMatch: ex?["match"] as? String ?? "",
                excerptPost: ex?["post"] as? String ?? "",
                sectionLabel: dict["label"] as? String))
        case "searchProgress":
            break // reserved for a progress UI; ignored in M3
        case "searchDone":
            delegate?.navigatorDidFinishSearch()
        default:
            break
        }
    }
}

extension EPUBNavigator: WKNavigationDelegate {
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Spec recovery contract: rebuild from the last committed state. The page reloads,
        // posts "ready", and the ready handler re-sends settings + lastLocator's CFI.
        webView.load(URLRequest(url: BookScheme.pageURL(bookID: bookID)))
    }
}

/// Breaks the WKUserContentController → handler retain cycle (it retains its handlers).
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var navigator: EPUBNavigator?
    init(_ navigator: EPUBNavigator) { self.navigator = navigator }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        // Content iframes (sandboxed, same-origin blob: book content) must never speak the
        // bridge protocol — only the top-level reader.html/bridge.js may post relocate/
        // loaded/error/ready messages. Reject anything from a non-main frame before it
        // reaches the actor-isolated handler.
        guard message.frameInfo.isMainFrame else { return }
        MainActor.assumeIsolated { navigator?.handle(message: message.body) }
    }
}
