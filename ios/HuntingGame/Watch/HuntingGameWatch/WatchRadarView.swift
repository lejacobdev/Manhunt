import SwiftUI

/// The tactical radar: concentric range rings, a slow scan sweep, one blip per nearby player and
/// a big distance readout for whoever is closest. The Watch cousin of the iPhone's
/// SpatialRadarView, and it points the same way: the top of the ring is the direction the player
/// is facing, so a blip at the top is straight ahead.
struct WTRadar: View {
    /// Nearest first.
    let blips: [WatchBlip]
    /// Which way the player faces, degrees from north. Nil = unknown, so the ring is north-up.
    let heading: Double?
    let accent: Color
    let centerValue: String
    let centerCaption: String
    /// Distance at which a blip reaches the outer ring; anything farther is pinned to the edge.
    var rangeMeters: Double = 100

    @Environment(\.isLuminanceReduced) private var isDimmed
    @State private var sweep: Double = 0
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let r = d / 2

            ZStack {
                // Halo, brighter the closer the nearest player is.
                Circle().fill(
                    RadialGradient(
                        colors: [accent.opacity(isDimmed ? 0 : 0.22), .clear],
                        center: .center, startRadius: r * 0.15, endRadius: r
                    )
                )

                // Rings.
                Circle().strokeBorder(accent.opacity(isDimmed ? 0.5 : 0.75), lineWidth: 2)
                Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1).padding(r * 0.36)
                Circle()
                    .strokeBorder(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .padding(r * 0.68)

                // Sweep — switched off on the always-on display, where nothing should animate.
                if !isDimmed {
                    Circle()
                        .fill(AngularGradient(
                            colors: [accent.opacity(0.32), .clear],
                            center: .center, startAngle: .degrees(0), endAngle: .degrees(75)
                        ))
                        .rotationEffect(.degrees(sweep))
                }

                forwardMarker(radius: r)

                ForEach(Array(blips.prefix(6).enumerated()), id: \.element.id) { index, blip in
                    blipView(blip, isNearest: index == 0, radius: r)
                }

                VStack(spacing: 0) {
                    Text(centerValue)
                        .font(.wtRounded(d * 0.27, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: centerValue)
                    Text(centerCaption)
                        .font(.wtMono(max(7, d * 0.055)))
                        .tracking(1.4)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
            }
            .frame(width: d, height: d)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { sweep = 360 }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// A small tick at the top of the ring marking "ahead" — or an "N" when the heading is unknown
    /// and the ring is therefore north-up.
    @ViewBuilder
    private func forwardMarker(radius r: CGFloat) -> some View {
        if heading != nil {
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 7))
                .foregroundStyle(Color.white.opacity(0.55))
                .position(x: r, y: 5)
        } else {
            Text("N")
                .font(.wtMono(8))
                .foregroundStyle(Color.white.opacity(0.5))
                .position(x: r, y: 8)
        }
    }

    private func blipView(_ blip: WatchBlip, isNearest: Bool, radius r: CGFloat) -> some View {
        let point = position(for: blip, radius: r)
        return ZStack {
            if isNearest {
                Circle().fill(accent.opacity(0.28))
                    .frame(width: 22, height: 22)
                    .scaleEffect(pulse ? 1.25 : 0.85)
            }
            Circle()
                .fill(isNearest ? accent : Color.white.opacity(0.55))
                .frame(width: isNearest ? 9 : 6, height: isNearest ? 9 : 6)
                .shadow(color: isNearest ? accent : .clear, radius: 4)
        }
        .position(point)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: point)
    }

    /// Where a player sits on the ring: angle from the direction we're facing, radius from a
    /// square-root scale so the last few metres — the ones that matter — aren't crammed together.
    private func position(for blip: WatchBlip, radius r: CGFloat) -> CGPoint {
        let radians = (blip.bearingDegrees - (heading ?? 0)) * .pi / 180
        let reach = min(1, (Double(blip.distanceMeters) / rangeMeters).squareRoot())
        let fraction = CGFloat(0.32 + 0.60 * reach)
        return CGPoint(
            x: r + r * fraction * CGFloat(sin(radians)),
            y: r - r * fraction * CGFloat(cos(radians))
        )
    }

    private var accessibilityText: String {
        guard let nearest = blips.first else { return "Radar. No one in range." }
        return "Radar. Nearest player \(nearest.distanceMeters) meters away."
    }
}
