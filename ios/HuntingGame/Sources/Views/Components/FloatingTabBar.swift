import SwiftUI

/// The four top-level screens the floating tab bar switches between — each already carries
/// its own accent color (matching the RadarSweepBackdrop tint each screen already uses), so
/// the bar's selected-item highlight and the collapsed circle's tint reuse the exact same
/// mapping instead of inventing a second one.
enum AppTab: String, CaseIterable, Identifiable {
    case play, friends, leaderboard, profile

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .play: return "gamecontroller.fill"
        case .friends: return "person.2.fill"
        case .leaderboard: return "trophy.fill"
        case .profile: return "person.crop.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .play: return "Play"
        case .friends: return "Friends"
        case .leaderboard: return "Leaderboard"
        case .profile: return "Profile"
        }
    }

    var accent: Color {
        switch self {
        case .play: return ADATheme.runnerGreen
        case .friends: return ADATheme.hunterRed
        case .leaderboard: return ADATheme.tacticalAmber
        case .profile: return ADATheme.spatialCyan
        }
    }
}

/// Replaces the system TabView chrome (a solid bar docked to the screen edge) with a
/// floating pill of tab items plus a separate circular button, mirroring the Apple News-
/// style bar: frosted glass, rounded, hovering above content with visible margin on every
/// side rather than a bar spanning full width flush with the bottom edge.
///
/// The circle doubles as the bar's own collapse toggle rather than being a fixed, unrelated
/// button (Apple News' circle is a permanent Search shortcut) — collapsed, it's the *entire*
/// bar: just that one circle, tinted with and showing the current tab's icon, sitting at the
/// trailing edge. Tapping it expands the full pill out to its leading side. The bar stays
/// present (expanded) by default and only ever collapses when the user taps the circle
/// themselves — no auto-collapse on idle or on scroll/swipe activity, so it's always there
/// to use unless deliberately tucked away. There's deliberately no separate "close" glyph:
/// the circle always shows the current tab's own icon in both states, since the icon itself
/// (plus the pill's absence) already communicates the collapsed state.
///
/// On iOS 26 the pill and the circle are two pieces of one Liquid Glass container sharing glass
/// identities, so collapsing reads as the pill draining into the circle rather than sliding out,
/// and the selected tab sits on a lens that glides between items.
struct FloatingTabBar: View {
    @Binding var selection: AppTab

    @State private var isExpanded = true
    @Namespace private var glassNamespace
    @Namespace private var lensNamespace

    private let circleDiameter: CGFloat = 58

    var body: some View {
        TacticalGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                if isExpanded {
                    pill
                        .transition(.tacticalGlassMorph(fallback: .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        )))
                } else {
                    Spacer(minLength: 0)
                }

                toggleCircle
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .animation(ADATheme.controlSpring, value: isExpanded)
        // The bar has a fixed height; past this size its labels would clip.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private var pill: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(ADATheme.controlSpring) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .tacticalFont(.symbol, size: 17, weight: .semibold)
                        Text(tab.label)
                            .tacticalFont(.telemetry, size: 9)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(selection == tab ? tab.accent : .white.opacity(0.64))
                    .frame(maxWidth: .infinity)
                    .frame(height: circleDiameter - 10)
                    .background {
                        if selection == tab {
                            Capsule()
                                .fill(tab.accent.opacity(0.16))
                                .overlay(Capsule().stroke(tab.accent.opacity(0.25), lineWidth: 0.5))
                                .matchedGeometryEffect(id: "lens", in: lensNamespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                // The bar keeps a fixed height at every text size, so — like Apple's own tab
                // bars — touch and hold shows the item enlarged in the middle of the screen.
                .accessibilityShowsLargeContentViewer {
                    Image(systemName: tab.icon)
                    Text(tab.label)
                }
            }
        }
        .padding(.horizontal, 5)
        .frame(height: circleDiameter)
        .frame(maxWidth: .infinity)
        .tacticalGlass(in: Capsule(), interactive: true)
        .tacticalGlassID("pill", in: glassNamespace)
    }

    private var toggleCircle: some View {
        Button {
            withAnimation(ADATheme.controlSpring) { isExpanded.toggle() }
        } label: {
            // Always the current tab's own icon — the pill's absence already says "collapsed".
            Image(systemName: selection.icon)
                .tacticalFont(.symbol, size: 19, weight: .bold)
                .foregroundColor(selection.accent)
                .frame(width: circleDiameter, height: circleDiameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tacticalGlass(in: Circle(), tint: selection.accent, interactive: true)
        .tacticalGlassID("circle", in: glassNamespace)
        // A fixed identity across expand/collapse, so the tint and glyph change reads as one
        // button changing state rather than being replaced.
        .id("floating-tab-bar-toggle")
        .accessibilityLabel(isExpanded ? "Hide tab bar" : "Show tab bar")
        .accessibilityShowsLargeContentViewer {
            Image(systemName: selection.icon)
            Text(isExpanded ? "Hide tab bar" : "Show tab bar")
        }
        .accessibilityValue(selection.label)
    }
}
