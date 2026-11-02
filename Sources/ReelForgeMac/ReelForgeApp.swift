import SwiftUI

@main
struct ReelForgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_360, height: 860)
    }
}
