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
    @ViewBuilder let content: (AppTab) -> Content

    @State private var dragTranslation: CGFloat = 0
    /// Latched once per drag, on its first meaningful movement, and held until release.
    /// Re-deciding the axis on every update (what this used to do) is what made an imperfect
    /// swipe unreliable: a diagonal drag stuttered, because any single frame where vertical
    /// movement happened to lead froze the page mid-slide, and a release whose *total*
    /// translation leaned vertical was thrown away outright no matter how far across the
    /// screen the finger had actually travelled.
    @State private var isHorizontalDrag: Bool?

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
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if isHorizontalDrag == nil {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    guard max(dx, dy) > 6 else { return }
                    // Biased toward paging: a drag has to be clearly *vertical* to be handed
                    // back to the page's own ScrollView, so a sloppy diagonal still pages
                    // instead of doing nothing at all.
                    isHorizontalDrag = dx > dy * 0.6
                }
                guard isHorizontalDrag == true else { return }

                dragTranslation = value.translation.width
                let progress = Double(currentIndex) - Double(value.translation.width / width)
                onProgressChange(min(max(progress, 0), Double(tabs.count - 1)))
            }
            .onEnded { value in
                defer { isHorizontalDrag = nil }
                guard isHorizontalDrag == true else {
                    withAnimation(ADATheme.controlSpring) { dragTranslation = 0 }
                    onProgressChange(Double(currentIndex))
                    return
                }
                // Direction comes from actual travel — predictedEndTranslation can flip sign
                // on a jittery release — while *how far it counts as having gone* takes the
                // larger of the two, so a short-but-fast flick commits on velocity alone just
                // as a slow deliberate drag commits on distance.
                let travelled = value.translation.width
                let distance = max(abs(travelled), abs(value.predictedEndTranslation.width))
                let threshold = width * 0.22

                var newIndex = currentIndex
                if distance > threshold {
                    if travelled < 0, currentIndex < tabs.count - 1 {
                        newIndex += 1
                    } else if travelled > 0, currentIndex > 0 {
                        newIndex -= 1
                    }
                }

                withAnimation(ADATheme.controlSpring) {
                    selection = tabs[newIndex]
                    dragTranslation = 0
                    // When the page doesn't actually change, `selection` doesn't either, so
                    // the parent's onChange never fires and its pageProgress would stay stuck
                    // at whatever fraction the drag reached — leaving the backdrop tint
                    // frozen mid-crossfade. Settling it explicitly is only needed here; the
                    // committing case is already covered by that onChange.
                    if newIndex == currentIndex {
                        onProgressChange(Double(currentIndex))
                    }
                }
            }
    }
}
