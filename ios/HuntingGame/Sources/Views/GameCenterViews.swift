import SwiftUI
import GameKit

/// Which Game Center screen to open.
enum GameCenterDestination: Identifiable {
    case leaderboards
    case achievements
    /// One specific board, keyed by the server's leaderboard sort ("wins", "catches", ...).
    case leaderboard(sort: String)

    var id: String {
        switch self {
        case .leaderboards: return "leaderboards"
        case .achievements: return "achievements"
        case .leaderboard(let sort): return "leaderboard-" + sort
        }
    }
}

/// Apple's own Game Center screens, hosted in SwiftUI.
struct GameCenterView: UIViewControllerRepresentable {
    let destination: GameCenterDestination
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> GKGameCenterViewController {
        let controller: GKGameCenterViewController
        switch destination {
        case .leaderboards:
            controller = GKGameCenterViewController(state: .leaderboards)
        case .achievements:
            controller = GKGameCenterViewController(state: .achievements)
        case .leaderboard(let sort):
            if let id = GameCenterCatalog.leaderboardID(forSort: sort) {
                controller = GKGameCenterViewController(leaderboardID: id, playerScope: .global, timeScope: .allTime)
            } else {
                controller = GKGameCenterViewController(state: .leaderboards)
            }
        }
        controller.gameCenterDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: GKGameCenterViewController, context: Context) {}

    final class Coordinator: NSObject, GKGameCenterControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
            onFinish()
        }
    }
}

/// The Game Center block on the Profile tab: whether it is connected, the switch that controls
/// sharing, and the way into the leaderboards and achievements.
struct GameCenterCard: View {
    @ObservedObject private var manager = GameCenterManager.shared
    @State private var destination: GameCenterDestination?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .foregroundColor(ADATheme.spatialCyan)
                Text("GAME CENTER")
                    .font(ADATheme.telemetryFont(size: 12))
                    .tracking(1.5)
                    .foregroundColor(.white)
                Spacer()
                statusChip
            }

            statusDetail

            if manager.isConnected {
                Toggle(isOn: $manager.isSharingEnabled) {
                    Text("Share my scores and achievements")
                        .font(ADATheme.uiFont(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .tint(ADATheme.spatialCyan)

                HStack(spacing: 10) {
                    Button {
                        destination = .leaderboards
                    } label: {
                        HStack { Image(systemName: "list.number"); Text("LEADERBOARDS") }
                    }
                    .buttonStyle(GlassButtonStyle(tint: ADATheme.spatialCyan))

                    Button {
                        destination = .achievements
                    } label: {
                        HStack { Image(systemName: "rosette"); Text("ACHIEVEMENTS") }
                    }
                    .buttonStyle(GlassButtonStyle(tint: ADATheme.tacticalAmber))
                }

                Text("Your Game Center name and stats appear on the public leaderboards. Turn sharing off to stop posting new scores.")
                    .font(ADATheme.uiFont(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            } else if manager.status == .needsSignIn {
                Button {
                    manager.presentSignIn()
                } label: {
                    HStack { Image(systemName: "person.crop.circle.badge.checkmark"); Text("SIGN IN TO GAME CENTER") }
                }
                .buttonStyle(GlowButtonStyle(tint: ADATheme.spatialCyan))
            }
        }
        .padding(16)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: ADATheme.spatialCyan)
        .padding(.horizontal)
        .sheet(item: $destination) { destination in
            GameCenterView(destination: destination) { self.destination = nil }
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch manager.status {
        case .connected:
            chip("CONNECTED", ADATheme.runnerGreen)
        case .needsSignIn:
            chip("SIGN IN", ADATheme.tacticalAmber)
        case .restricted:
            chip("UNAVAILABLE", ADATheme.hunterRed)
        case .signedOut:
            chip("OFFLINE", .white.opacity(0.4))
        case .unknown:
            ProgressView().tint(ADATheme.spatialCyan)
        }
    }

    private func chip(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(ADATheme.telemetryFont(size: 9))
            .tracking(1.2)
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch manager.status {
        case .connected(let alias):
            Text("Signed in as " + alias + ". Your stats and achievements are kept in sync with Game Center.")
                .font(ADATheme.uiFont(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        case .needsSignIn:
            Text("Sign in to Game Center to compare your stats with players around the world and earn achievements.")
                .font(ADATheme.uiFont(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        case .signedOut:
            Text("You're not signed in to Game Center. Sign in from Settings, Game Center, then come back here.")
                .font(ADATheme.uiFont(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        case .restricted:
            Text("Game Center isn't available for this Apple Account, so nothing is shared.")
                .font(ADATheme.uiFont(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        case .unknown:
            EmptyView()
        }
    }
}
