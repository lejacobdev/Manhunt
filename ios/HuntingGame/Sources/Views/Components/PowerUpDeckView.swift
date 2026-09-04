import SwiftUI

/// The tactical equipment tray, docked as a collapsible panel alongside the other
/// bottom-dock panels rather than floating in the middle of the HStack — that middle
/// slot gets crushed to near-zero width on iPhone whenever both side dock columns are
/// occupied (e.g. a hunter who's also host), which used to wrap "TACTICAL EQUIPMENT"
/// into an unreadable single-character-per-line column spanning the full screen height.
/// Each chip springs on press, fires a rigid haptic tap, and — once the server confirms
/// the use_powerup event — animates out of the deck as the socket-driven inventory shrinks.
struct PowerUpDeckView: View {
    let inventory: [PowerUpType]
    let onActivate: (PowerUpType) -> Void
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureHeader(icon: "shippingbox.fill", title: "EQUIPMENT (\(inventory.count))", tint: .white.opacity(0.7), isExpanded: $isExpanded)

            if isExpanded {
                Group {
                    if inventory.isEmpty {
                        Text("None collected — find a power-up spawn on the map.")
                            .font(ADATheme.uiFont(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.35))
                    } else {
                        // Stacked vertically, sized to content rather than a fixed/scrolling
                        // row — the panel's own height grows and shrinks with how many
                        // items are actually held instead of hiding extras behind a scroll.
                        VStack(spacing: 8) {
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
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(12)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
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
