import SwiftUI

/// A dismissible "an update is available" nudge — see UpdateChecker for why this exists
/// instead of a system update prompt (there's no App Store listing to prompt from).
struct UpdateBannerView: View {
    let update: UpdateChecker.AvailableUpdate
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(ADATheme.spatialCyan)

            VStack(alignment: .leading, spacing: 2) {
                Text("UPDATE AVAILABLE — v\(update.version)")
                    .font(ADATheme.telemetryFont(size: 11))
                    .foregroundColor(.white)
                Text(update.changelog)
                    .font(ADATheme.uiFont(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
                Text("Install it from the SideStore/AltStore app.")
                    .font(ADATheme.telemetryFont(size: 9))
                    .foregroundColor(ADATheme.spatialCyan.opacity(0.8))
                    .padding(.top, 1)
            }

            Spacer(minLength: 4)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(12)
        .glassCard(cornerRadius: ADATheme.controlCornerRadius, tint: ADATheme.spatialCyan)
        .padding(.horizontal)
    }
}
