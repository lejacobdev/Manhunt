import SwiftUI

/// The explicit, declinable "check in" App Store guideline 5.1.2(i) requires before a
/// player's location is ever shown to others on a map — shown once per match, in the
/// lobby, before `LocationManager` is ever started for that match. There's no silent
/// auto-check-in path anywhere else: `GameLobbyView` only calls
/// `locationManager.requestAuthorizationAndStart()` after this screen's accept action.
struct LocationConsentView: View {
    let isSubmitting: Bool
    let errorMessage: String?
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ZStack {
            RadarSweepBackdrop(accent: ADATheme.spatialCyan)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "location.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundColor(ADATheme.spatialCyan)
                    .shadow(color: ADATheme.spatialCyan.opacity(0.6), radius: 16)

                Text("SHARE YOUR LOCATION?")
                    .font(ADATheme.displayFont(size: 20))
                    .foregroundColor(.white)

                Text("For this match, other players will be able to see your live position on the radar and map. This is required to play — nothing is shared until you say yes, and it's asked again for every match.")
                    .font(ADATheme.uiFont(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)

                if let errorMessage {
                    Text(errorMessage)
                        .font(ADATheme.telemetryFont(size: 12))
                        .foregroundColor(ADATheme.hunterRed)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        onAccept()
                    } label: {
                        if isSubmitting {
                            ProgressView().tint(.black)
                        } else {
                            HStack { Image(systemName: "location.fill"); Text("SHARE MY LOCATION") }
                        }
                    }
                    .buttonStyle(GlowButtonStyle(tint: ADATheme.spatialCyan, isLoading: isSubmitting))

                    Button("DECLINE & LEAVE") {
                        onDecline()
                    }
                    .font(ADATheme.telemetryFont(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(1.5)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .disabled(isSubmitting)
            }
            .adaptiveContentWidth()
        }
        .obsidianBackdrop()
    }
}
