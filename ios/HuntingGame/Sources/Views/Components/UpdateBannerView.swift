import SwiftUI

/// A dismissible "an update is available" nudge — see UpdateChecker for why this exists
/// instead of a system update prompt (there's no App Store listing to prompt from).
struct UpdateBannerView: View {
    let update: UpdateChecker.AvailableUpdate
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .tacticalFont(.symbol, size: 18, weight: .bold)
                .foregroundColor(ADATheme.spatialCyan)

            VStack(alignment: .leading, spacing: 2) {
                Text("UPDATE AVAILABLE — v\(update.version)")
                    .tacticalFont(.telemetry, size: 11)
                    .foregroundColor(.white)
                Text(update.changelog)
                    .tacticalFont(.ui, size: 11, weight: .medium)
                    .tacticalText(.secondary)
                    .lineLimit(2)
                Text("Install it from the SideStore/AltStore app.")
                    .tacticalFont(.telemetry, size: 9)
                    .foregroundColor(ADATheme.spatialCyan.opacity(0.8))
                    .padding(.top, 1)
            }

            Spacer(minLength: 4)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .tacticalText(.tertiary)
            }
            .accessibilityLabel("Dismiss update notice")
        }
        .padding(12)
        .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: ADATheme.spatialCyan)
        .padding(.horizontal)
    }
}
