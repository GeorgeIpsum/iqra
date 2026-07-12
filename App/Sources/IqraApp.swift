import SwiftUI
import IqraLibrary

@main
struct IqraApp: App {
    @State private var model = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model)
                .task { await model.start() }
        }
    }
}
