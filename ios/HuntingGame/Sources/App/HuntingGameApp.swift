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
