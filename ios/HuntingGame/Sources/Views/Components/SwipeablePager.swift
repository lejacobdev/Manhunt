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
    /// Called with each tab and the x offset that tab must apply to a full-bleed
    /// background layer for it to appear pinned to the screen while the page itself
    /// slides — see the note on `body` for why pages paint their own. Nil while the page
    /// is entirely off screen, meaning there's nothing to draw.
    @ViewBuilder let content: (AppTab, CGFloat?) -> Content

    @State private var dragTranslation: CGFloat = 0

    private var currentIndex: Int { tabs.firstIndex(of: selection) ?? 0 }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            HStack(spacing: 0) {
                // Each page paints its own copy of the shared backdrop, because a page is
                // a NavigationStack and fills its frame with an opaque background that
                // would cover anything drawn behind the pager. Handing each one the
                // negation of its current on-screen origin cancels the pager's own
                // translation, so those copies all land on the same screen rect and read
                // as a single backdrop that stays put while the content slides over it.
                // Clipping each page to its frame is what keeps that illusion intact:
                // a page only ever reveals the slice of the backdrop it currently covers.
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    let pageOrigin = CGFloat(index - currentIndex) * width + dragTranslation
                    content(tab, abs(pageOrigin) < width ? -pageOrigin : nil)
                        .frame(width: width)
                        .clipped()
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
