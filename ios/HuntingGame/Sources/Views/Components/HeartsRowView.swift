import SwiftUI

/// Minecraft-style heart row, docked above the equipment panel. Purely a display of
/// `hearts`/`maxHearts` — all the actual heal/damage logic lives server-side and reaches
/// this view via GameViewModel.hearts.
///
/// Hearts can exceed the role's starting maximum (ADRENALINE grants +2), so the row grows
/// to fit and tints the surplus differently — a bonus heart spends exactly like any other
/// one, including as a gamble stake, but it's worth seeing that you're carrying it.
struct HeartsRowView: View {
    let hearts: Int
    let maxHearts: Int

    private var slots: Int { max(hearts, maxHearts) }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<slots, id: \.self) { index in
                Image(systemName: index < hearts ? "heart.fill" : "heart")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(color(for: index))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: ADATheme.hunterRed)
        .animation(ADATheme.controlSpring, value: hearts)
    }

    private func color(for index: Int) -> Color {
        guard index < hearts else { return .white.opacity(0.25) }
        return index >= maxHearts ? ADATheme.runnerGreen : ADATheme.hunterRed
    }
}
