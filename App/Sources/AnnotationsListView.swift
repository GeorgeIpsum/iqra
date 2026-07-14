// App/Sources/AnnotationsListView.swift
import SwiftUI
import IqraReader

struct AnnotationsListView: View {
    let annotations: [Annotation]
    let onOpen: (Annotation) -> Void
    let onDelete: (Annotation) -> Void
    @Environment(\.dismiss) private var dismiss

    private var highlights: [Annotation] { annotations.filter { $0.kind != .bookmark } }
    private var bookmarks: [Annotation] { annotations.filter { $0.kind == .bookmark } }

    var body: some View {
        NavigationStack {
            List {
                if !highlights.isEmpty {
                    Section("Highlights & Notes") {
                        ForEach(highlights) { a in row(a) }
                            .onDelete { $0.map { highlights[$0] }.forEach(onDelete) }
                    }
                }
                if !bookmarks.isEmpty {
                    Section("Bookmarks") {
                        ForEach(bookmarks) { a in row(a) }
                            .onDelete { $0.map { bookmarks[$0] }.forEach(onDelete) }
                    }
                }
                if annotations.isEmpty {
                    ContentUnavailableView("No annotations yet", systemImage: "highlighter",
                        description: Text("Select text to highlight, or bookmark a page."))
                }
            }
            .navigationTitle("Annotations")
            .toolbar { ToolbarItem { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder private func row(_ a: Annotation) -> some View {
        Button { onOpen(a); dismiss() } label: {
            HStack(alignment: .top, spacing: 10) {
                if let color = a.color {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: color.cssColor)).frame(width: 4)
                } else {
                    Image(systemName: "bookmark.fill").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(a.locator.textContext?.highlight ?? a.locator.tocLabel ?? "Bookmark")
                        .font(.callout).lineLimit(3)
                    if let note = a.note, !note.isEmpty {
                        Label(note, systemImage: "note.text").font(.caption)
                            .foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
