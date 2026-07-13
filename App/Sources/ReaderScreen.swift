// App/Sources/ReaderScreen.swift
import SwiftUI
import WebKit
import IqraReader

struct ReaderScreen: View {
    @State var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAppearance = false
    @State private var showTOC = false

    var body: some View {
        WebViewContainer(webView: model.navigator.webView)
            .ignoresSafeArea(edges: .bottom)
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
                    Button("Appearance", systemImage: "textformat.size") { showAppearance = true }
                }
            }
            .popover(isPresented: $showAppearance) { AppearanceControls(model: model) }
            .sheet(isPresented: $showTOC) { TOCList(items: model.toc, model: model) }
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
