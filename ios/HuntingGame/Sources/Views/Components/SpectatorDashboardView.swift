import SwiftUI

/// Read-only observer panel for the SPECTATOR role: the live roster with role/status
/// telemetry, same data feed as HostControlPanelView but with no override controls —
/// spectators can watch and tap a player to center the map on them, nothing more.
/// Lives in GameView's bottom side dock, not floating over the map.
struct SpectatorDashboardView: View {
    let players: [PlayerState]
    let focusedPlayerId: String?
    let onFocus: (String?) -> Void

    /// Starts collapsed — see HostControlPanelView's isExpanded for why.
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureHeader(icon: "binoculars.fill", title: "WATCH: \(players.count)", tint: ADATheme.neutralGray, isExpanded: $isExpanded)

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
        }
        .padding(12)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius, tint: ADATheme.neutralGray)
    }

    /// Compact two-line row — see HostControlPanelView.row(for:) for why this
    /// dropped from a single wide HStack to a narrower stacked layout.
    private func row(for player: PlayerState) -> some View {
        let isFocused = focusedPlayerId == player.id
        return Button {
            onFocus(isFocused ? nil : player.id)
        } label: {
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
                    Spacer(minLength: 4)
                    Image(systemName: isFocused ? "scope" : "location")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isFocused ? ADATheme.spatialCyan : .white.opacity(0.4))
                }
                HStack(spacing: 6) {
                    Text(player.role.displayName.uppercased())
                    if player.role == .hunter || player.role == .runner {
                        Label("\(player.hearts)", systemImage: "heart.fill")
                    }
                    Spacer(minLength: 4)
                    statusBadge(for: player)
                }
                .font(ADATheme.telemetryFont(size: 9))
                .foregroundColor(.white.opacity(0.5))
            }
            .padding(8)
            .background(isFocused ? ADATheme.spatialCyan.opacity(0.12) : Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func statusBadge(for player: PlayerState) -> some View {
        Group {
            if player.isOut {
                Text("OUT").foregroundColor(ADATheme.hunterRed)
            } else if player.isJailed {
                Text("JAILED").foregroundColor(ADATheme.tacticalAmber)
            } else if player.isExtracted {
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
