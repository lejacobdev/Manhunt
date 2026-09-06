import SwiftUI

@main
struct HuntingGameApp: App {
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
            if authSession.isAuthenticated { presence.start() }
        }
        .onChange(of: authSession.isAuthenticated) { isAuthenticated in
            if isAuthenticated {
                presence.start()
            } else {
                presence.stop()
            }
        }
    }
}
