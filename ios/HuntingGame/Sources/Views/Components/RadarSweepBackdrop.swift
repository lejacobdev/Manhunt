import SwiftUI

/// A large, ambient echo of `SpatialRadarView`'s rings + rotating sweep — no
/// needle, no distance readout, just the tactical drawing scaled up to fill
/// the screen — used behind pre-mission chrome (sign-in, Mission Control, Friends,
/// Leaderboard, Profile, the lobby) so those screens read as part of the same HUD
/// system as the live map instead of a plain form with a generic glow behind it.
struct RadarSweepBackdrop: View {
    var accent: Color = ADATheme.runnerGreen
    var center: UnitPoint = .center

    /// Shared by every instance, fixed once for the life of the process — the sweep's
    /// angle is derived from elapsed real time against this single epoch rather than each
    /// instance animating its own `@State` from 0. That's what keeps it at the identical
    /// rotation on every screen it appears on: a screen mounting its backdrop mid-sweep
    /// picks up exactly where every other screen's sweep already is, so switching tabs (or
    /// pushing/popping a screen that re-creates this view) only ever changes `accent`, not
    /// the angle — nothing restarts or jumps.
    private static let epoch = Date()
    private static let rotationPeriod: Double = 9

    private static func rotationDegrees(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(epoch)
        let fraction = elapsed.truncatingRemainder(dividingBy: rotationPeriod) / rotationPeriod
        return fraction * 360
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let scanRotation = Self.rotationDegrees(at: timeline.date)

            GeometryReader { proxy in
                // Sized to the screen's diagonal (not just its width/height) and centered, so
                // the glow and sweep genuinely reach every corner of the screen rather than
                // sitting in a smaller circle with visible dead space around it — the radial
                // gradient's outer edge lands almost exactly on the corners at this radius.
                let side = (proxy.size.width * proxy.size.width + proxy.size.height * proxy.size.height).squareRoot() * 1.05

                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [accent.opacity(0.10), .clear],
                                center: .center,
                                startRadius: side * 0.04,
                                endRadius: side * 0.5
                            )
                        )

                    Canvas { context, size in
                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                        for fraction: CGFloat in [0.18, 0.32, 0.46] {
                            let r = size.width / 2 * fraction
                            var ring = Path()
                            ring.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                            context.stroke(ring, with: .color(.white.opacity(0.05)), lineWidth: 1)
                        }
                        var reticle = Path()
                        reticle.move(to: CGPoint(x: c.x, y: 0))
                        reticle.addLine(to: CGPoint(x: c.x, y: size.height))
                        reticle.move(to: CGPoint(x: 0, y: c.y))
                        reticle.addLine(to: CGPoint(x: size.width, y: c.y))
                        context.stroke(reticle, with: .color(.white.opacity(0.035)), lineWidth: 1)
                    }

                    Circle()
                        .fill(
                            AngularGradient(
                                colors: [accent.opacity(0.16), .clear],
                                center: .center,
                                startAngle: .degrees(scanRotation),
                                endAngle: .degrees(scanRotation - 110)
                            )
                        )
                        .rotationEffect(.degrees(scanRotation))
                }
                .frame(width: side, height: side)
                .position(x: proxy.size.width * center.x, y: proxy.size.height * center.y)
            }
        }
        .allowsHitTesting(false)
    }
}
