import SwiftUI

/// Host-only admin panel: battery/motion telemetry per player plus tap-to-override
/// catch status and a force-end-game control. Shown whenever this player hosted the
/// match, regardless of which role (HUNTER/RUNNER/SPECTATOR) they chose to play as.
struct HostControlPanelView: View {
    let players: [PlayerState]
    let onOverride: (String, Bool) -> Void
    let onEndGame: () -> Void

    @State private var confirmingEndGame = false
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureHeader(icon: "shield.fill", title: "HOST CONTROLS: \(players.count)", tint: ADATheme.spatialCyan, isExpanded: $isExpanded)

            if isExpanded {
                Group {
                    if players.isEmpty {
                        Text("Waiting for players to report in.")
                            .font(ADATheme.uiFont(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                    } else {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(players) { player in
                                    row(for: player)
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                }
                .clipped()
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                confirmingEndGame = true
            } label: {
                HStack {
                    Image(systemName: "stop.circle.fill")
                    Text("END GAME")
                }
            }
            .buttonStyle(GlowButtonStyle(tint: ADATheme.hunterRed))
        }
        .padding(18)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: ADATheme.spatialCyan)
        .padding(.horizontal, 16)
        .confirmationDialog(
            "End the match for everyone?",
            isPresented: $confirmingEndGame,
            titleVisibility: .visible
        ) {
            Button("End Game", role: .destructive, action: onEndGame)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(for player: PlayerState) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ADATheme.accent(for: player.role))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.username.uppercased())
                    .font(ADATheme.uiFont(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                HStack(spacing: 8) {
                    Label("\(player.battery)%", systemImage: batteryIcon(for: player.battery))
                    Label(player.isMovingOnFoot ? "On foot" : "Stationary", systemImage: player.isMovingOnFoot ? "figure.walk" : "pause.circle")
                    if let squad = player.squad {
                        Text(squad.uppercased())
                    }
                }
                .font(ADATheme.telemetryFont(size: 9))
                .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            statusBadge(for: player)

            if player.role == .hunter || player.role == .runner {
                Button {
                    onOverride(player.id, !player.isCaught)
                } label: {
                    Image(systemName: player.isCaught ? "arrow.uturn.backward.circle.fill" : "hand.raised.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(player.isCaught ? ADATheme.runnerGreen : ADATheme.hunterRed)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
