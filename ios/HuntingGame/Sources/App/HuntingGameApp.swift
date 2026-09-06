import SwiftUI

@main
struct HuntingGameApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var authSession = AuthSession.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authSession)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var authSession: AuthSession
    @StateObject private var presence = PresenceService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if authSession.isAuthenticated {
                LobbyView()
                    .environmentObject(presence)
            } else {
                AuthView()
            }
        }
        // Friend codes scanned outside the app land here as huntinggame://add-friend?…
        // (the https QR target redirects to it). Parked on the router rather than acted on
        // directly: the link can arrive before sign-in, or before any screen that could
        // show the confirm prompt exists.
        .onOpenURL { url in
            DeepLinkRouter.shared.handle(url)
        }
        .onAppear {
            if authSession.isAuthenticated {
                presence.start()
                PushNotificationManager.shared.requestAuthorizationIfNeeded()
                PushNotificationManager.shared.flushPendingTokenIfNeeded()
            }
            Task { await UpdateChecker.shared.checkIfNeeded() }
        }
        .onChange(of: authSession.isAuthenticated) { isAuthenticated in
            if isAuthenticated {
                presence.start()
                PushNotificationManager.shared.requestAuthorizationIfNeeded()
                PushNotificationManager.shared.flushPendingTokenIfNeeded()
            } else {
                presence.stop()
            }
        }
        // Catches "left it running for a day, came back" the same way a fresh launch
        // would — .onAppear alone only fires once per process lifetime.
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await UpdateChecker.shared.checkIfNeeded() }
            }
        }
    }
}
