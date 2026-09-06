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
/// trailing edge. Tapping it expands the full pill out to its leading side. It also auto-
/// collapses on its own after a few seconds of not being touched, or the instant the parent
/// reports scroll/swipe activity elsewhere on screen (`activitySignal`) — the bar shouldn't
/// keep sitting open over content nobody's using it. There's deliberately no separate
/// "close" glyph: the circle always shows the current tab's own icon in both states, since
/// collapsing now happens on its own rather than needing an explicit affordance for it.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    /// Bumped by the parent on every scroll/page-swipe touch anywhere in the content below
    /// — any change collapses the bar immediately (if it was open) and resets the idle timer.
    var activitySignal: Int = 0

    @State private var isExpanded = true
    @State private var collapseWorkItem: DispatchWorkItem?

    private let circleDiameter: CGFloat = 58
    private let autoCollapseDelay: TimeInterval = 3

    var body: some View {
        HStack(spacing: 10) {
            if isExpanded {
                pill
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else {
                Spacer(minLength: 0)
            }

            toggleCircle
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .animation(ADATheme.controlSpring, value: isExpanded)
        .onAppear { scheduleAutoCollapse() }
        .onChange(of: activitySignal) { _ in
            collapseWorkItem?.cancel()
            if isExpanded {
                withAnimation(ADATheme.controlSpring) { isExpanded = false }
            }
        }
    }

    private func scheduleAutoCollapse() {
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem {
            withAnimation(ADATheme.controlSpring) { isExpanded = false }
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoCollapseDelay, execute: work)
    }

    private var pill: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(ADATheme.controlSpring) { selection = tab }
                    scheduleAutoCollapse()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: .semibold))
                        Text(tab.label)
                            .font(ADATheme.telemetryFont(size: 9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundColor(selection == tab ? tab.accent : .white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: circleDiameter)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: circleDiameter / 2, tint: selection.accent)
    }

    private var toggleCircle: some View {
        Button {
            let expanding = !isExpanded
            withAnimation(ADATheme.controlSpring) { isExpanded = expanding }
            if expanding { scheduleAutoCollapse() } else { collapseWorkItem?.cancel() }
        } label: {
            // Always the current tab's own icon — no separate "close" glyph, since
            // collapsing is now automatic rather than something this button needs to spell
            // out as an action of its own.
            Image(systemName: selection.icon)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(selection.accent)
                .frame(width: circleDiameter, height: circleDiameter)
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: circleDiameter / 2, tint: selection.accent)
        // A fixed identity across the expand/collapse transition — without this the glow/
        // icon-swap reads as the circle itself being replaced rather than one button
        // changing state, since its tint and glyph both change at the same moment the pill
        // beside it does.
        .id("floating-tab-bar-toggle")
    }
}
