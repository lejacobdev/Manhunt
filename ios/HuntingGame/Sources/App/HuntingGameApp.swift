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

    var body: some View {
        Group {
            if authSession.isAuthenticated {
                LobbyView()
            } else {
                AuthView()
            }
        }
    }
}
