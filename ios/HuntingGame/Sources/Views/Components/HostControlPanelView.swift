import SwiftUI

/// Host-only admin panel: a compact roster (battery + status) with tap-to-override
/// catch status, plus a force-end-game control. Shown whenever this player hosted
/// the match, regardless of which role (HUNTER/RUNNER/SPECTATOR) they chose to play
/// as. Lives in GameView's bottom side dock, not floating over the map.
struct HostControlPanelView: View {
    let players: [PlayerState]
    let onOverride: (String, Bool) -> Void
    let onEndGame: () -> Void

    @State private var confirmingEndGame = false
    /// Starts collapsed — this now lives in the bottom dock beside the map, not
    /// floating full-width, so the default should stay out of the way until tapped.
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureHeader(icon: "shield.fill", title: "HOST: \(players.count)", tint: ADATheme.spatialCyan, isExpanded: $isExpanded)

            if isExpanded {
                Group {
                    if players.isEmpty {
                        Text("Waiting for players.")
                            .font(ADATheme.uiFont(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    } else {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(players) { player in
                                    row(for: player)
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                }
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Button {
                confirmingEndGame = true
            } label: {
                HStack {
                    Image(systemName: "stop.circle.fill")
                    Text("END GAME")
                }
                .font(ADATheme.telemetryFont(size: 11))
            }
            .buttonStyle(GlowButtonStyle(tint: ADATheme.hunterRed))
        }
        .padding(12)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: ADATheme.spatialCyan)
        .confirmationDialog(
            "End the match for everyone?",
            isPresented: $confirmingEndGame,
            titleVisibility: .visible
        ) {
            Button("End Game", role: .destructive, action: onEndGame)
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Compact two-line row — this panel now lives in a ~150pt-wide dock column
    /// rather than a near-full-width card, so motion state/squad tag (shown
    /// elsewhere, e.g. the map pin) are dropped here to keep it fitting.
    private func row(for player: PlayerState) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ADATheme.accent(for: player.role))
                    .frame(width: 7, height: 7)
                Text(player.username.uppercased())
                    .font(ADATheme.uiFont(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 6) {
                Label("\(player.battery)%", systemImage: batteryIcon(for: player.battery))
                Spacer(minLength: 4)
                statusBadge(for: player)
                if player.role == .hunter || player.role == .runner {
                    Button {
                        onOverride(player.id, !player.isCaught)
                    } label: {
                        Image(systemName: player.isCaught ? "arrow.uturn.backward.circle.fill" : "hand.raised.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(player.isCaught ? ADATheme.runnerGreen : ADATheme.hunterRed)
                    }
                }
            }
            .font(ADATheme.telemetryFont(size: 9))
            .foregroundColor(.white.opacity(0.5))
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusBadge(for player: PlayerState) -> some View {
        Group {
            if player.isExtracted {
                Text("SAFE")
                    .foregroundColor(ADATheme.runnerGreen)
            } else if player.isCaught {
                Text("CAUGHT")
                    .foregroundColor(ADATheme.hunterRed)
            } else {
                Text("ACTIVE")
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .font(ADATheme.telemetryFont(size: 10))
    }

    private func batteryIcon(for level: Int) -> String {
        switch level {
        case ..<20: return "battery.0"
        case 20..<50: return "battery.25"
        case 50..<80: return "battery.75"
        default: return "battery.100"
        }
    }
}
