import SwiftUI

/// A short walkthrough of how a match works: shown once before someone's first game, and any
/// time from Mission Control. Uses the real radar so what they learn here is what they'll see.
struct HowToPlayView: View {
    var onFinish: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var page: Int

    init(startPage: Int = 0, onFinish: @escaping () -> Void = {}) {
        self.onFinish = onFinish
        _page = State(initialValue: startPage)
    }

    private struct Page {
        let title: String
        let body: String
        let art: AnyView
    }

    private var pages: [Page] {
        [
            Page(
                title: "HUNTERS VS RUNNERS",
                body: "Everyone plays outside in a play area the host draws on the map. Hunters chase, runners hide and run. Runners win if any of them are still free when time runs out.",
                art: AnyView(roles)
            ),
            Page(
                title: "THE RADAR",
                body: "Hunters' radar shows which way runners are and how far. Runners' compass shows nearby hunters. In most matches it pings every so often instead of updating live, so keep moving.",
                art: AnyView(
                    SpatialRadarView(
                        distanceMeters: nil,
                        bearingDegrees: nil,
                        targets: [
                            RadarBearing(id: "a", username: "leon", distanceMeters: 64, bearingDegrees: 35),
                            RadarBearing(id: "b", username: "mira", distanceMeters: 210, bearingDegrees: 250),
                        ],
                        currentHeading: 0,
                        role: .hunter,
                        diameter: 210
                    )
                    .accessibilityHidden(true)
                )
            ),
            Page(
                title: "MAKING A CATCH",
                body: "Tag a runner in real life, then tap them on the map. They confirm on their phone, even from the lock screen. If they don't answer within 20 seconds, the catch counts.",
                art: AnyView(symbolArt("hand.raised.fill", tint: ADATheme.hunterRedText))
            ),
            Page(
                title: "HEARTS AND JAIL",
                body: "Runners have hearts, and every catch costs one. Lose the last and you're out. Without jail you keep playing with a 30-second shield; with jail on, you walk to the jail and a free teammate can break everyone out.",
                art: AnyView(heartsArt)
            ),
            Page(
                title: "POWER-UPS",
                body: "Walk to a power-up on the map to collect it, then use it from Equipment. Some are for hunters, some for runners.",
                art: AnyView(powerUpsArt)
            ),
            Page(
                title: "STAY IN THE ZONE",
                body: "The play area shrinks as the match goes on. Outside it you lose hearts, so watch the edge. Play safe: watch for traffic and stay out of private property.",
                art: AnyView(symbolArt("circle.dashed.inset.filled", tint: ADATheme.spatialCyan))
            ),
        ]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        pageView(pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button {
                    if page < pages.count - 1 {
                        withAnimation(ADATheme.controlSpring) { page += 1 }
                    } else {
                        finish()
                    }
                } label: {
                    Text(page < pages.count - 1 ? "NEXT" : "LET'S PLAY")
                }
                .buttonStyle(GlowButtonStyle(tint: ADATheme.runnerGreen))
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .adaptiveContentWidth()
            .frame(maxWidth: .infinity)
            .obsidianBackdrop()
            .navigationTitle("How to Play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(page < pages.count - 1 ? "Skip" : "Done") { finish() }
                        .foregroundColor(ADATheme.spatialCyan)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func finish() {
        onFinish()
        dismiss()
    }

    private func pageView(_ page: Page) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                page.art
                    .frame(height: 230)
                    .frame(maxWidth: .infinity)
                Text(page.title)
                    .tacticalFont(.display, size: 20)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(page.body)
                    .tacticalFont(.ui, size: 15, weight: .medium)
                    .tacticalText(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
            }
            .padding(.top, 24)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Art

    private var roles: some View {
        HStack(spacing: 36) {
            roleBadge("scope", "HUNTER", ADATheme.hunterRed)
            roleBadge("figure.run", "RUNNER", ADATheme.runnerGreen)
        }
    }

    private func roleBadge(_ icon: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .tacticalFont(.symbol, size: 38, weight: .bold)
                .foregroundColor(tint)
                .frame(width: 96, height: 96)
                .background(Circle().fill(tint.opacity(0.14)))
                .overlay(Circle().stroke(tint.opacity(0.4), lineWidth: 1))
            Text(label)
                .tacticalFont(.telemetry, size: 12)
                .foregroundColor(.white)
        }
        .accessibilityHidden(true)
    }

    private func symbolArt(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .tacticalFont(.symbol, size: 64, weight: .bold)
            .foregroundColor(tint)
            .frame(width: 150, height: 150)
            .background(Circle().fill(tint.opacity(0.12)))
            .overlay(Circle().stroke(tint.opacity(0.35), lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var heartsArt: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                ForEach(0..<3) { index in
                    Image(systemName: index < 2 ? "heart.fill" : "heart")
                        .tacticalFont(.symbol, size: 34, weight: .bold)
                        .foregroundColor(ADATheme.hunterRedText)
                }
            }
            Image(systemName: "lock.open.fill")
                .tacticalFont(.symbol, size: 40, weight: .bold)
                .foregroundColor(ADATheme.tacticalAmber)
        }
        .accessibilityHidden(true)
    }

    private var powerUpsArt: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 12), count: 3), spacing: 12) {
            ForEach(PowerUpType.allCases, id: \.self) { type in
                VStack(spacing: 6) {
                    Image(systemName: type.iconName)
                        .tacticalFont(.symbol, size: 20, weight: .bold)
                        .foregroundColor(ADATheme.spatialCyan)
                    Text(type.displayName)
                        .tacticalFont(.ui, size: 10, weight: .semibold)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: 84, height: 70)
                .glassCard(cornerRadius: ADATheme.controlCornerRadius)
            }
        }
        .accessibilityHidden(true)
    }
}
