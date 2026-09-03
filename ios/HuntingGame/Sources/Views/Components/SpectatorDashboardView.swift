import SwiftUI

/// Read-only observer panel for the SPECTATOR role: the live roster with role/status
/// telemetry, same data feed as HostControlPanelView but with no override controls —
/// spectators can watch and tap a player to center the map on them, nothing more.
struct SpectatorDashboardView: View {
    let players: [PlayerState]
    let focusedPlayerId: String?
    let onFocus: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "binoculars.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("OBSERVING: \(players.count)")
                    .font(ADATheme.telemetryFont(size: 12))
            }
            .foregroundColor(ADATheme.neutralGray)

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
        .padding(18)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: ADATheme.neutralGray)
        .padding(.horizontal, 16)
    }

    private func row(for player: PlayerState) -> some View {
        let isFocused = focusedPlayerId == player.id
        return Button {
            onFocus(isFocused ? nil : player.id)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(ADATheme.accent(for: player.role))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.username.uppercased())
                        .font(ADATheme.uiFont(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text(player.role.displayName.uppercased())
                        .font(ADATheme.telemetryFont(size: 9))
                        .foregroundColor(.white.opacity(0.45))
                }

                Spacer()

                statusBadge(for: player)

                Image(systemName: isFocused ? "scope" : "location")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isFocused ? ADATheme.spatialCyan : .white.opacity(0.4))
            }
            .padding(10)
            .background(isFocused ? ADATheme.spatialCyan.opacity(0.12) : Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func statusBadge(for player: PlayerState) -> some View {
        Group {
            if player.isExtracted {
                Text("SAFE").foregroundColor(ADATheme.runnerGreen)
            } else if player.isCaught {
                Text("CAUGHT").foregroundColor(ADATheme.hunterRed)
            } else {
                Text("ACTIVE").foregroundColor(.white.opacity(0.4))
            }
        }
        .font(ADATheme.telemetryFont(size: 10))
    }
}
