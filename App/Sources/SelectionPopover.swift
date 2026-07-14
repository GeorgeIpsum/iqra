// App/Sources/SelectionPopover.swift
import SwiftUI
import IqraReader

/// The five-swatch color bar shown above a live text selection.
struct SelectionColorBar: View {
    let onPick: (HighlightColor) -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button { onPick(color) } label: {
                    Circle().fill(Color(hex: color.cssColor)).frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.rawValue)
            }
            Divider().frame(height: 24)
            Button("Copy", systemImage: "doc.on.doc", action: onCopy).labelStyle(.iconOnly)
        }
        .padding(10)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4)
    }
}

/// The note editor for a tapped highlight.
struct NoteEditor: View {
    let annotation: Annotation
    let onSave: (String) -> Void
    let onChangeColor: (HighlightColor) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(annotation: Annotation, onSave: @escaping (String) -> Void,
         onChangeColor: @escaping (HighlightColor) -> Void, onDelete: @escaping () -> Void) {
        self.annotation = annotation; self.onSave = onSave
        self.onChangeColor = onChangeColor; self.onDelete = onDelete
        _text = State(initialValue: annotation.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Highlight") {
                    HStack(spacing: 12) {
                        ForEach(HighlightColor.allCases, id: \.self) { c in
                            Button { onChangeColor(c) } label: {
                                Circle().fill(Color(hex: c.cssColor)).frame(width: 24, height: 24)
                                    .overlay(Circle().strokeBorder(.primary,
                                        lineWidth: annotation.color == c ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c.rawValue)
                        }
                    }
                }
                Section("Note") {
                    TextEditor(text: $text).frame(minHeight: 120)
                }
                Section {
                    Button("Delete Highlight", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .navigationTitle("Highlight")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSave(text); dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Hex-string → SwiftUI Color (the overlay colors are stored as "#RRGGBB").
extension Color {
    init(hex: String) {
        let h = hex.dropFirst()
        var v: UInt64 = 0; Scanner(string: String(h)).scanHexInt64(&v)
        self = Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}
