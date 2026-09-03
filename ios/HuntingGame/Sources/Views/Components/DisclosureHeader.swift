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
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(ADATheme.telemetryFont(size: 12))
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .foregroundColor(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
