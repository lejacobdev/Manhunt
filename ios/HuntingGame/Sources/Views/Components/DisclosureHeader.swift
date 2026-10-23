import SwiftUI

/// A tappable header row — icon, title, chevron — for HUD panels whose body can grow
/// tall (a roster list, a runner list) and would otherwise cover a large chunk of the
/// live match map, especially stacked with other panels or on iPad's larger screen.
/// The chevron rotates to reflect `isExpanded`; tapping anywhere on the row toggles it.
struct DisclosureHeader: View {
    let icon: String
    let title: String
    let tint: Color
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(ADATheme.controlSpring) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .tacticalFont(.symbol, size: 12, weight: .bold)
                Text(title)
                    .tacticalFont(.telemetry, size: 12)
                    // One line that shrinks to fit rather than breaking a word mid-way at the
                    // largest text sizes ("EQUI / PMEN / T").
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer()
                Image(systemName: "chevron.down")
                    .tacticalFont(.symbol, size: 11, weight: .bold)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .foregroundColor(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.capitalized)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Collapses this panel" : "Expands this panel")
    }
}
