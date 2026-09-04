import SwiftUI

/// Minecraft-style heart row, docked above the equipment panel. Purely a display of
/// `hearts`/`maxHearts` — all the actual heal/damage/heal-back logic lives server-side
/// and reaches this view via GameViewModel.hearts.
struct HeartsRowView: View {
    let hearts: Int
    let maxHearts: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<maxHearts, id: \.self) { index in
                Image(systemName: index < hearts ? "heart.fill" : "heart")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(index < hearts ? ADATheme.hunterRed : .white.opacity(0.25))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: ADATheme.hunterRed)
        .animation(ADATheme.controlSpring, value: hearts)
    }
}
