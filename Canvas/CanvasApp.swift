import SwiftUI

@main
struct CanvasApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(store.settings.appearanceMode.colorScheme)
        }
    }
}
