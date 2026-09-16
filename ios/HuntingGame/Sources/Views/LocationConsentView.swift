import SwiftUI

/// The explicit, declinable check-in App Store guideline 5.1.2(i) requires before location
/// is used — shown at each of the only two points the app ever starts it, each explaining
/// what it's for and, just as importantly, who does and doesn't get to see the result.
/// There is no silent path around either: `LocationManager` is started nowhere else.
struct LocationConsentView: View {
    enum Purpose {
        /// Centring the play-area map on the host while they draw it. Stays on the device.
        case playAreaSetup
        /// Live position shared with every other player for the length of one match.
        case match

        var icon: String {
            switch self {
            case .playAreaSetup: return "map.fill"
            case .match: return "location.fill"
            }
        }

        var title: String {
            switch self {
            case .playAreaSetup: return "USE YOUR LOCATION?"
            case .match: return "SHARE YOUR LOCATION?"
            }
        }

        var explanation: String {
            switch self {
            case .playAreaSetup:
                return "To draw the play area, the map needs to open where you're actually standing. This one is just for you — your position isn't sent to any other player, and location stops the moment you close the map."
            case .match:
                return "For this match, every other player will see your live position on their radar and map. This is what makes the game work — nothing is shared until you say yes, and you'll be asked again for every match you play."
            }
        }

        /// What happens if location isn't granted at the system prompt that follows — said
        /// plainly rather than left to be discovered. Purely informational now: this screen
        /// no longer offers a button that skips that prompt (App Store guideline 5.1.1(iv) —
        /// a custom message ahead of a permission request must always lead to the real
        /// request, never to an in-app substitute for declining it).
        var declineNote: String {
            switch self {
            case .playAreaSetup:
                return "If you don't allow it, you can still draw the area — you'll just have to find it on the map yourself."
            case .match:
                return "If you don't allow it, you won't be able to play this match. Nothing is shared either way."
            }
        }

        // Deliberately generic — must not read as the action itself (e.g. "Use My
        // Location"), only as proceeding to the system permission request that follows.
        var acceptLabel: String { "CONTINUE" }

        var accent: Color {
            switch self {
            case .playAreaSetup: return ADATheme.tacticalAmber
            case .match: return ADATheme.spatialCyan
            }
        }
    }

    var purpose: Purpose = .match
    var isSubmitting: Bool = false
    var errorMessage: String?
    // No onDecline: this screen always proceeds to the real system permission request. If
    // the user doesn't want to grant it, they say so there — not on this screen — and the
    // caller reacts to `LocationManager.authorizationStatus` turning `.denied`/`.restricted`.
    let onAccept: () -> Void

    var body: some View {
        ZStack {
            RadarSweepBackdrop(accent: purpose.accent)
                .edgesIgnoringSafeArea(.all)

            VStack(spacing: 18) {
                Spacer()

                Image(systemName: purpose.icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundColor(purpose.accent)
                    .shadow(color: purpose.accent.opacity(0.6), radius: 16)

                Text(purpose.title)
                    .font(ADATheme.displayFont(size: 20))
                    .foregroundColor(.white)

                Text(purpose.explanation)
                    .font(ADATheme.uiFont(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)

                Text(purpose.declineNote)
                    .font(ADATheme.uiFont(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 34)

                if let errorMessage {
                    Text(errorMessage)
                        .font(ADATheme.telemetryFont(size: 12))
                        .foregroundColor(ADATheme.hunterRed)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }

                Spacer()

                Button {
                    onAccept()
                } label: {
                    if isSubmitting {
                        ProgressView().tint(.black)
                    } else {
                        HStack {
                            Image(systemName: purpose.icon)
                            Text(purpose.acceptLabel)
                        }
                    }
                }
                .buttonStyle(GlowButtonStyle(tint: purpose.accent, isLoading: isSubmitting))
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .disabled(isSubmitting)
            }
            .adaptiveContentWidth()
        }
        .obsidianBackdrop()
    }
}
