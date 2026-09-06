import SwiftUI

/// A large, ambient echo of `SpatialRadarView`'s rings + rotating sweep — no
/// needle, no distance readout, just the tactical drawing scaled up to fill
/// the screen — used behind pre-mission chrome (sign-in, Mission Control) so
/// those screens read as part of the same HUD system as the live map instead
/// of a plain form with a generic glow behind it.
struct RadarSweepBackdrop: View {
    var accent: Color = ADATheme.runnerGreen
    var center: UnitPoint = .top

    @State private var scanRotation: Double = 0

    var body: some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height) * 1.3

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
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) {
                scanRotation = 360
            }
        }
    }
}
