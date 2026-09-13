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
