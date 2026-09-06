import SwiftUI

/// Horizontal paging between the app's top-level tabs, driven by a hand-rolled drag gesture
/// rather than `TabView(.page)` — a plain page-style TabView only exposes the *settled*
/// selection, with no way to read continuous drag progress mid-swipe, which is what the
/// shared radar backdrop needs to crossfade its tint smoothly as you drag instead of
/// snapping the moment a swipe commits.
///
/// The drag gesture only actually claims the touch once it's clearly more horizontal than
/// vertical (checked on every update, not just at the start), so a vertical scroll inside a
/// page's own ScrollView is never hijacked into a page swipe.
struct SwipeablePager<Content: View>: View {
    let tabs: [AppTab]
    @Binding var selection: AppTab
    /// Continuous position in `[0, tabs.count - 1]`, fractional while mid-drag — the parent
    /// derives the backdrop's interpolated tint from this on every update.
    var onProgressChange: (Double) -> Void = { _ in }
    /// Fired on every drag update (regardless of direction) — the parent uses this purely
    /// as an activity signal to collapse the floating tab bar, not for paging itself.
    var onDragActivity: () -> Void = {}
    @ViewBuilder let content: (AppTab) -> Content

    @State private var dragTranslation: CGFloat = 0

    private var currentIndex: Int { tabs.firstIndex(of: selection) ?? 0 }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    content(tab)
                        .frame(width: width)
                }
            }
            .offset(x: -CGFloat(currentIndex) * width + dragTranslation)
            .gesture(dragGesture(width: width))
        }
        .clipped()
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                onDragActivity()
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragTranslation = value.translation.width
                let progress = Double(currentIndex) - Double(value.translation.width / width)
                onProgressChange(min(max(progress, 0), Double(tabs.count - 1)))
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    withAnimation(ADATheme.controlSpring) { dragTranslation = 0 }
                    onProgressChange(Double(currentIndex))
                    return
                }
                // A fast flick commits even short of the halfway mark — predictedEndTranslation
                // already accounts for velocity, so this reads as "where would it have ended up
                // if released to coast," not just "how far has it moved so far."
                let predicted = value.predictedEndTranslation.width
                let threshold = width * 0.3
                var newIndex = currentIndex
                if predicted < -threshold, currentIndex < tabs.count - 1 {
                    newIndex += 1
                } else if predicted > threshold, currentIndex > 0 {
                    newIndex -= 1
                }
                // Deliberately no onProgressChange call here (unlike the revert branch
                // above) — this changes `selection`, and the parent already mirrors any
                // selection change (tap-driven or this) into pageProgress via its own
                // onChange, so calling it again here would just fire two redundant,
                // slightly-competing animations at the same target value.
                withAnimation(ADATheme.controlSpring) {
                    selection = tabs[newIndex]
                    dragTranslation = 0
                }
            }
    }
}
