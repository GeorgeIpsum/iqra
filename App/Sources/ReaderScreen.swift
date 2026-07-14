// App/Sources/ReaderScreen.swift
import SwiftUI
import WebKit
import IqraReader
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Reads the size of the view it's attached to via `.background`, without altering layout.
private struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct ReaderScreen: View {
    @State var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAppearance = false
    @State private var showTOC = false
    @State private var showAnnotations = false
    @State private var showSearch = false
    // Defaults to "infinite" so, before the first layout pass reports a real size, the
    // clamp math below is a no-op and behaves exactly like the old top/left-only clamp.
    @State private var containerSize = CGSize(width: CGFloat.infinity, height: CGFloat.infinity)

    var body: some View {
        WebViewContainer(webView: model.navigator.webView)
            .ignoresSafeArea(edges: .bottom)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: SizePreferenceKey.self, value: proxy.size)
            })
            .onPreferenceChange(SizePreferenceKey.self) { containerSize = $0 }
            .navigationTitle(model.title ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup {
                    Text("\(model.progressPercent)%").font(.caption).foregroundStyle(.secondary)
                    Button("Previous", systemImage: "chevron.left") { model.navigator.prev() }
                    Button("Next", systemImage: "chevron.right") { model.navigator.next() }
                    Button("Contents", systemImage: "list.bullet") { showTOC = true }
                        .disabled(model.toc.isEmpty)
                    Button("Find", systemImage: "magnifyingglass") { showSearch = true }
                    Button("Appearance", systemImage: "textformat.size") { showAppearance = true }
                    Button(model.isCurrentPositionBookmarked ? "Bookmarked" : "Bookmark",
                           systemImage: model.isCurrentPositionBookmarked ? "bookmark.fill" : "bookmark") {
                        model.toggleBookmarkAtCurrentPosition()
                    }
                    Button("Annotations", systemImage: "list.bullet.rectangle") { showAnnotations = true }
                }
            }
            .popover(isPresented: $showAppearance) { AppearanceControls(model: model) }
            .sheet(isPresented: $showTOC) { TOCList(items: model.toc, model: model) }
            .overlay(alignment: .topLeading) {
                if let sel = model.currentSelection {
                    // The bar's width isn't known before layout; 260pt is a reasonable
                    // estimate for the 5 swatches + divider + copy button (with padding).
                    let barWidth: CGFloat = 260
                    let barHeight: CGFloat = 44
                    let maxX = max(8, containerSize.width - barWidth - 8)
                    let maxY = max(8, containerSize.height - barHeight - 8)
                    // Anchor above the selection when there's room; clamp on every edge so a
                    // selection near the trailing/bottom/top edge still renders on-screen.
                    let x = min(max(8, sel.rect.x), maxX)
                    let y = min(max(8, sel.rect.y - 52), maxY)
                    SelectionColorBar(
                        onPick: { model.createHighlight(color: $0) },
                        onCopy: {
                            #if os(macOS)
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sel.text, forType: .string)
                            #else
                            UIPasteboard.general.string = sel.text
                            #endif
                            model.clearSelection()
                        },
                        onDismiss: { model.clearSelection() })
                        // The rect is in web-view coordinates (bridge already mapped iframe→host).
                        .offset(x: x, y: y)
                        .transition(.opacity)
                }
            }
            .sheet(item: Binding(get: { model.activeAnnotation },
                                  set: { if $0 == nil { model.dismissActiveAnnotation() } })) { ann in
                NoteEditor(annotation: ann,
                           onSave: { model.setNote($0, for: ann) },
                           onChangeColor: { model.changeColor($0, for: ann) },
                           onDelete: { model.deleteAnnotation(ann) })
            }
            .sheet(isPresented: $showAnnotations) {
                AnnotationsListView(annotations: model.annotations,
                                    onOpen: { model.goTo($0) },
                                    onDelete: { model.deleteAnnotation($0) })
            }
            .sheet(isPresented: $showSearch, onDismiss: { model.clearSearch() }) {
                SearchView(model: model)
            }
            .alert("Reader error", isPresented: .init(get: { model.readerError != nil },
                                                      set: { if !$0 { model.readerError = nil } })) {
                Button("OK") { model.readerError = nil }
            } message: { Text(model.readerError ?? "") }
            #if os(macOS)
            .onKeyPress(.leftArrow) { model.navigator.prev(); return .handled }
            .onKeyPress(.rightArrow) { model.navigator.next(); return .handled }
            #endif
    }
}

private struct AppearanceControls: View {
    @Bindable var model: ReaderViewModel

    // ReaderTheme is Equatable but not Hashable (it's a plain struct in IqraReader), and
    // SwiftUI's Picker/.tag require Hashable selection values. Bridge through a local,
    // Hashable-friendly enum rather than adding a retroactive conformance in app code.
    private enum ThemeChoice: Hashable {
        case light, sepia, dark
        var theme: ReaderTheme {
            switch self {
            case .light: .light
            case .sepia: .sepia
            case .dark: .dark
            }
        }
        init(_ theme: ReaderTheme) {
            switch theme {
            case .light: self = .light
            case .sepia: self = .sepia
            default: self = .dark
            }
        }
    }

    private var themeChoice: Binding<ThemeChoice> {
        Binding(get: { ThemeChoice(model.settings.theme) },
                set: { model.settings.theme = $0.theme })
    }

    var body: some View {
        Form {
            Picker("Theme", selection: themeChoice) {
                Text("Light").tag(ThemeChoice.light)
                Text("Sepia").tag(ThemeChoice.sepia)
                Text("Dark").tag(ThemeChoice.dark)
            }
            Stepper("Text size: \(model.settings.fontSizePercent)%",
                    value: $model.settings.fontSizePercent, in: 70...200, step: 10)
            Stepper(value: $model.settings.lineHeight, in: 1.0...2.2, step: 0.1) {
                Text("Line height: \(String(format: "%.1f", model.settings.lineHeight))")
            }
            Toggle("Justify text", isOn: $model.settings.justify)
            Picker("Layout", selection: $model.settings.flow) {
                Text("Pages").tag(ReaderSettings.Flow.paginated)
                Text("Scroll").tag(ReaderSettings.Flow.scrolled)
            }
        }
        .padding()
        .frame(minWidth: 280)
    }
}

private struct TOCList: View {
    let items: [TOCItem]
    let model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List { TOCLevel(items: items, model: model, dismiss: dismiss) }
                .navigationTitle("Contents")
                .toolbar { ToolbarItem { Button("Done") { dismiss() } } }
        }
    }
}

private struct TOCLevel: View {
    let items: [TOCItem]
    let model: ReaderViewModel
    let dismiss: DismissAction

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Button(item.label) {
                if let href = item.href { model.navigator.goTo(cfi: href) } // goTo accepts hrefs too
                dismiss()
            }
            if let sub = item.subitems {
                TOCLevel(items: sub, model: model, dismiss: dismiss).padding(.leading, 16)
            }
        }
    }
}

private struct WebViewContainer {
    let webView: WKWebView
}

#if os(macOS)
extension WebViewContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension WebViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
