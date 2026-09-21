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
    // Gates both AuthView and the authenticated app — Apple requires agreement to terms
    // before either registering or signing in (App Store guideline 1.2), not just before
    // registering, so this sits ahead of the isAuthenticated branch entirely.
    @AppStorage("hasAcceptedTerms") private var hasAcceptedTerms = false
    /// Whether the rules have been agreed to, and whether the first-launch rules screen has
    /// been shown at all. Two flags, because declining is allowed here: the app still opens,
    /// but hosting or joining re-asks (see LobbyView). Only `hasSeenRules` suppresses this
    /// gate, so a decline doesn't trap the player on it forever.
    @AppStorage("hasAcceptedRules") private var hasAcceptedRules = false
    @AppStorage("hasSeenRules") private var hasSeenRules = false

    var body: some View {
        Group {
            if !hasAcceptedTerms {
                TermsGateView { hasAcceptedTerms = true }
            } else if !hasSeenRules {
                RulesView(
                    onAccept: {
                        hasAcceptedRules = true
                        hasSeenRules = true
                    },
                    onDecline: { hasSeenRules = true }
                )
            } else if authSession.isAuthenticated {
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
            startGameCenterIfReady()
            Task { await UpdateChecker.shared.checkIfNeeded() }
        }
        .onChange(of: authSession.isAuthenticated) { isAuthenticated in
            if isAuthenticated {
                presence.start()
                PushNotificationManager.shared.requestAuthorizationIfNeeded()
                PushNotificationManager.shared.flushPendingTokenIfNeeded()
                startGameCenterIfReady()
            } else {
                presence.stop()
            }
        }
        // Catches "left it running for a day, came back" the same way a fresh launch
        // would — .onAppear alone only fires once per process lifetime.
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await UpdateChecker.shared.checkIfNeeded() }
                // Throttled inside: cheap when nothing changed, and it catches a match finished
                // while the app was in the background.
                Task { await GameCenterManager.shared.syncFromServer() }
            }
        }
        // Someone who accepts the terms and rules after they were already signed in (an account
        // from before those gates existed) becomes eligible at that moment, not next launch.
        .onChange(of: hasAcceptedTerms) { _ in startGameCenterIfReady() }
        .onChange(of: hasSeenRules) { _ in startGameCenterIfReady() }
    }

    /// Game Center is only started for a signed-in player who has been through the terms and the
    /// rules. Nothing about it should appear in front of either gate.
    private func startGameCenterIfReady() {
        guard authSession.isAuthenticated, hasAcceptedTerms, hasSeenRules else { return }
        GameCenterManager.shared.startAuthenticationIfNeeded()
    }
}
