import SwiftUI

/// A titled switch row for boolean setup options — the app's first use of a native
/// `Toggle` (every other selection in the setup flow is a segmented `Picker` or a
/// `Slider`); this is the natural control for a genuine on/off setting.
struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var tint: Color = ADATheme.spatialCyan

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(ADATheme.telemetryFont(size: 13))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(ADATheme.uiFont(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn.animation(ADATheme.controlSpring))
                .labelsHidden()
                .tint(tint)
        }
        .padding(16)
        .glassCard(cornerRadius: ADATheme.cardCornerRadius)
    }
}
