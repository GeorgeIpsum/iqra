import SwiftUI
import UniformTypeIdentifiers
import IqraLibrary

struct LibraryView: View {
    @Bindable var model: LibraryViewModel
    @State private var showImporter = false
    @State private var showQuarantine = false

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]
    private static let bookTypes: [UTType] = [
        UTType("org.idpf.epub-container") ?? .epub, .pdf,
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(model.books) { book in
                        VStack(alignment: .leading, spacing: 6) {
                            CoverView(url: model.coverURL(for: book.id))
                            Text(book.title).font(.callout).lineLimit(2)
                            Text(book.authors).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Library")
            .searchable(text: $model.searchText, prompt: "Title, author, description")
            .toolbar {
                ToolbarItem {
                    Picker("Sort", selection: $model.sort) {
                        Text("Title").tag(BookSort.titleSort)
                        Text("Recent").tag(BookSort.recentlyAdded)
                        Text("Author").tag(BookSort.authorSort)
                    }
                }
                ToolbarItem {
                    Button("Quarantine", systemImage: "exclamationmark.triangle") {
                        showQuarantine = true
                    }
                    .disabled(model.quarantined.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Import", systemImage: "plus") { showImporter = true }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.bookTypes,
                          allowsMultipleSelection: true) { result in
                if case let .success(urls) = result {
                    Task { await model.importFiles(urls) }
                }
            }
            .sheet(isPresented: $showQuarantine) {
                QuarantineList(items: model.quarantined)
            }
            .alert("Same identifier as an existing book",
                   isPresented: .init(get: { model.pendingIdentifierMatch != nil },
                                      set: { if !$0 { model.pendingIdentifierMatch = nil } })) {
                Button("Attach to existing book") { Task { await model.resolveIdentifierMatch(attach: true) } }
                Button("Import as new book") { Task { await model.resolveIdentifierMatch(attach: false) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This file shares an identifier (e.g. ISBN) with a book already in your library.")
            }
            .alert("Error", isPresented: .init(get: { model.lastError != nil },
                                               set: { if !$0 { model.lastError = nil } })) {
                Button("OK") { model.lastError = nil }
            } message: { Text(model.lastError ?? "") }
        }
    }
}

private struct CoverView: View {
    let url: URL?
    var body: some View {
        Group {
            if let url, let data = try? Data(contentsOf: url) {
                #if os(macOS)
                if let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else { placeholder }
                #else
                if let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else { placeholder }
                #endif
            } else { placeholder }
        }
        .frame(width: 140, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 2)
    }
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            .overlay(Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary))
    }
}

private struct QuarantineList: View {
    let items: [ImportItemRecord]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(items) { item in
                VStack(alignment: .leading) {
                    Text((item.sourceDisplayPath as NSString).lastPathComponent).font(.body)
                    Text(item.rejection ?? item.status).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle("Not Imported")
            .toolbar { ToolbarItem { Button("Done") { dismiss() } } }
        }
    }
}
