import SwiftUI

/// Minecraft-style heart row, docked above the equipment panel. Purely a display of
/// `hearts`/`maxHearts` — all the actual heal/damage logic lives server-side and reaches
/// this view via GameViewModel.hearts.
///
/// Hearts can exceed the role's starting maximum (ADRENALINE grants +2), so the row grows
/// to fit and tints the surplus differently — a bonus heart spends exactly like any other
/// one, but it's worth seeing that you're carrying it.
///
/// Losing one is deliberately loud: the heart that just emptied bursts outward and fades
/// over the empty slot left behind, and the whole row flinches. A heart quietly switching
/// from filled to outline in a corner panel is far too easy to miss mid-chase, which made
/// zone damage in particular feel like it wasn't happening at all.
struct HeartsRowView: View {
    let hearts: Int
    let maxHearts: Int

    /// The slot that just emptied, shown mid-burst. Nil whenever nothing is breaking.
    @State private var breakingIndex: Int?
    @State private var breakAnimating = false
    @State private var flinch = false
    /// Last value seen, so a *gain* (adrenaline) doesn't play the loss animation.
    @State private var previousHearts: Int?

    private var slots: Int { max(hearts, maxHearts) }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<slots, id: \.self) { index in
                Image(systemName: index < hearts ? "heart.fill" : "heart")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(color(for: index))
                    .overlay {
                        if breakingIndex == index {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(ADATheme.hunterRed)
                                .shadow(color: ADATheme.hunterRed, radius: 8)
                                .scaleEffect(breakAnimating ? 2.4 : 1)
                                .rotationEffect(.degrees(breakAnimating ? 28 : 0))
                                .opacity(breakAnimating ? 0 : 1)
                        }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: ADATheme.hunterRed)
        .scaleEffect(flinch ? 1.08 : 1)
        .offset(x: flinch ? -5 : 0)
        .animation(ADATheme.controlSpring, value: hearts)
        .onAppear { previousHearts = hearts }
        .onChange(of: hearts) { newValue in
            defer { previousHearts = newValue }
            guard let previous = previousHearts, newValue < previous else { return }
            playLoss(at: newValue)
        }
    }

    /// `index` is the slot that just emptied — with `hearts` already down to its new value,
    /// that's the first outline in the row.
    private func playLoss(at index: Int) {
        breakingIndex = index
        breakAnimating = false
        flinch = true

        withAnimation(.easeOut(duration: 0.55)) { breakAnimating = true }
        withAnimation(ADATheme.controlSpring.delay(0.12)) { flinch = false }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Guarded so a second hit landing inside this window doesn't have its own burst
            // cancelled by the first one's cleanup.
            guard breakingIndex == index else { return }
            breakingIndex = nil
            breakAnimating = false
        }
    }

    private func color(for index: Int) -> Color {
        guard index < hearts else { return .white.opacity(0.25) }
        return index >= maxHearts ? ADATheme.runnerGreen : ADATheme.hunterRed
    }
}
