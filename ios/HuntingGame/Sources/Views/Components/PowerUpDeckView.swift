import SwiftUI

/// The horizontally-scrolling tactical equipment tray. Each chip springs on
/// press, fires a rigid haptic tap, and — once the server confirms the
/// use_powerup event — animates out of the deck as the socket-driven
/// inventory array shrinks.
struct PowerUpDeckView: View {
    let inventory: [PowerUpType]
    let onActivate: (PowerUpType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TACTICAL EQUIPMENT")
                .font(ADATheme.telemetryFont(size: 10))
                .foregroundColor(.white.opacity(0.4))
                .padding(.leading, 24)

            if inventory.isEmpty {
                Text("No equipment collected yet — find a power-up spawn on the map.")
                    .font(ADATheme.uiFont(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Indexed rather than keyed by PowerUpType.id: a player can hold
                        // duplicates of the same power-up, and ForEach requires unique ids.
                        ForEach(Array(inventory.enumerated()), id: \.offset) { _, item in
                            PowerUpChip(item: item) {
                                HapticsEngine.shared.powerUpActivated()
                                onActivate(item)
                            }
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .padding(.vertical, 16)
        .glassCard(cornerRadius: ADATheme.sheetCornerRadius)
        .animation(ADATheme.controlSpring, value: inventory)
    }
}

private struct PowerUpChip: View {
    let item: PowerUpType
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.iconName)
                    .font(.system(size: 16, weight: .bold))
                Text(item.displayName.uppercased())
                    .font(ADATheme.telemetryFont(size: 12))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(tint.opacity(0.2))
            .foregroundColor(tint)
            .overlay(
                RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous)
                    .stroke(tint.opacity(0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var tint: Color { ADATheme.accent(for: item) }
}
