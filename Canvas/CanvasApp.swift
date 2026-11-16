import SwiftUI

@main
struct CanvasApp: App {
    @StateObject private var store = AppStore()

    @ViewBuilder private var appRoot: some View {
#if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--canvas-simulator-album-additions")
            || ProcessInfo.processInfo.arguments.contains("--canvas-simulator-cleanup") {
            SimulatorAlbumScenario()
        } else { RootView() }
#else
        RootView()
#endif
    }

    var body: some Scene {
        WindowGroup {
            appRoot
                .environmentObject(store)
                .preferredColorScheme(store.settings.appearanceMode.colorScheme)
        }
    }
}
