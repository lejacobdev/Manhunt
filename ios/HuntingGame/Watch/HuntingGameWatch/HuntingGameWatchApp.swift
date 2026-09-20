import SwiftUI

@main
struct HuntingGameWatchApp: App {
    @StateObject private var connectivity = WatchConnectivityManager.shared
    private let initialPage: WatchPage

    init() {
        #if DEBUG
        // Simulator screenshots: `-WatchScenario <name> [-WatchPage <page>]` shows a fixed state.
        initialPage = WatchPreviewScenarios.applyLaunchArguments(to: WatchConnectivityManager.shared) ?? .radar
        #else
        initialPage = .radar
        #endif
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(connectivity: connectivity, initialPage: initialPage)
        }
    }
}
