import SwiftUI

@main
struct HuntingGameWatchApp: App {
    @StateObject private var connectivity = WatchConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            WatchGameView(connectivity: connectivity)
        }
    }
}
