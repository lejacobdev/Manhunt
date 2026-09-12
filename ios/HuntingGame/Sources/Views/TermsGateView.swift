import SwiftUI

/// Shown once, before either registering or signing in — Apple requires apps with
/// user-generated content to show terms of use and get explicit agreement before account
/// creation/login (App Store guideline 1.2). `RootView` gates on `hasAcceptedTerms` ahead
/// of both `AuthView` and the authenticated app, so this is the very first thing anyone
/// sees on a fresh install.
struct TermsGateView: View {
    let onAccept: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                RadarSweepBackdrop(accent: ADATheme.spatialCyan)
                    .edgesIgnoringSafeArea(.all)

                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 20) {
                            VStack(spacing: 6) {
                                HuntingGameWordmark(size: 30)
                                    .shadow(color: ADATheme.spatialCyan.opacity(0.5), radius: 16)

                                Text("BEFORE YOU START")
                                    .font(ADATheme.telemetryFont(size: 12))
                                    .foregroundColor(.white.opacity(0.4))
                                    .tracking(2)
                            }
                            .padding(.top, 12)

                            VStack(alignment: .leading, spacing: 14) {
                                gateRow(
                                    icon: "location.fill",
                                    text: "Your location is only ever shared during a match, and only after you explicitly check in for it — never automatically."
                                )
                                gateRow(
                                    icon: "flag.fill",
                                    text: "Every player can be reported or blocked from their profile. We review reports and act on abusive behavior."
                                )
                                gateRow(
                                    icon: "figure.walk",
                                    text: "This is a real-world, physical game. Obey local laws, stay aware of your surroundings, and play at your own risk."
                                )
                            }
                            .padding(20)
                            .glassCard(cornerRadius: ADATheme.cardCornerRadius)
                            .padding(.horizontal)

                            VStack(spacing: 8) {
                                Text("By continuing, you agree to our")
                                    .font(ADATheme.uiFont(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                                HStack(spacing: 4) {
                                    Link("Terms of Use", destination: URL(string: "https://lejacob.dev/terms.html")!)
                                    Text("and")
                                        .foregroundColor(.white.opacity(0.6))
                                    Link("Privacy Policy", destination: URL(string: "https://lejacob.dev/privacy.html")!)
                                }
                                .font(ADATheme.uiFont(size: 13, weight: .semibold))
                                .tint(ADATheme.spatialCyan)
                            }
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                            Button("I AGREE — CONTINUE") {
                                onAccept()
                            }
                            .buttonStyle(GlowButtonStyle(tint: ADATheme.spatialCyan))
                            .padding(.horizontal, 24)
                            .padding(.top, 4)

                            Spacer(minLength: 20)
                        }
                        .padding(.top, 20)
                        .frame(minHeight: proxy.size.height)
                        .adaptiveContentWidth()
                    }
                }
            }
            .obsidianBackdrop()
        }
    }

    private func gateRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ADATheme.spatialCyan)
                .frame(width: 20)
            Text(text)
                .font(ADATheme.uiFont(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
