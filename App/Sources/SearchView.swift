// App/Sources/SearchView.swift
import SwiftUI
import IqraReader

struct SearchView: View {
    @Bindable var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.searchHits) { hit in
                    Button { model.goToHit(hit); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            (Text(hit.excerptPre) + Text(hit.excerptMatch).bold() + Text(hit.excerptPost))
                                .font(.callout).lineLimit(3)
                            if let label = hit.sectionLabel, !label.isEmpty {
                                Text(label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if model.isSearching { HStack { ProgressView(); Text("Searching…") } }
                else if model.searchHits.isEmpty && !model.searchQuery.isEmpty {
                    ContentUnavailableView.search(text: model.searchQuery)
                }
            }
            .navigationTitle("Find in Book")
            #if os(iOS)
            .searchable(text: $model.searchQuery, placement: .navigationBarDrawer(displayMode: .always))
            #else
            .searchable(text: $model.searchQuery)
            #endif
            .onSubmit(of: .search) { model.runSearch() }
            .toolbar { ToolbarItem { Button("Done") { model.clearSearch(); dismiss() } } }
        }
    }
}
