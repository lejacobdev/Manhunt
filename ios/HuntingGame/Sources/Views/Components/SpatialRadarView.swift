import SwiftUI

/// The runner's tactical compass: a Canvas-drawn radar reticle with a rotating
/// scan sweep, a spring-loaded bearing needle that always points at the
/// nearest hunter, and a live distance readout. Feeds the escalating
/// CoreHaptics proximity pulse once distance drops under 25m.
struct SpatialRadarView: View {
    let distanceMeters: Int?
    let bearingDegrees: Double?
    let currentHeading: Double
    let role: PlayerRole
    /// Outer diameter of the gauge. Every internal measurement is derived from this as a
    /// fraction of the original 260pt design, so the whole thing scales down cleanly for
    /// the dock-sized placement instead of clipping/overflowing its glass card.
    var diameter: CGFloat = 260

    @State private var pulseScale: CGFloat = 1.0
    @State private var scanRotation: Double = 0.0
    @State private var ringPulse: CGFloat = 1.0

    private var scale: CGFloat { diameter / 260 }

    var body: some View {
        ZStack {
            // Outer glowing halo — intensifies as danger increases.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accentColor.opacity(haloOpacity), .clear],
                        center: .center,
                        startRadius: 40 * scale,
                        endRadius: 140 * scale
                    )
                )
                .frame(width: 280 * scale, height: 280 * scale)
                .scaleEffect(ringPulse)

            // Concentric radar rings & crosshair grid.
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radii: [CGFloat] = [40 * scale, 80 * scale, 120 * scale]

                for radius in radii {
                    var path = Path()
                    path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.stroke(path, with: .color(Color.white.opacity(0.12)), lineWidth: 1)
                }

                let inset: CGFloat = 10 * scale
                var reticlePath = Path()
                reticlePath.move(to: CGPoint(x: center.x, y: inset))
                reticlePath.addLine(to: CGPoint(x: center.x, y: size.height - inset))
                reticlePath.move(to: CGPoint(x: inset, y: center.y))
                reticlePath.addLine(to: CGPoint(x: size.width - inset, y: center.y))
                context.stroke(reticlePath, with: .color(Color.white.opacity(0.08)), lineWidth: 1)
            }
            .frame(width: 240 * scale, height: 240 * scale)

            // Rotating radar sweep beam.
            Circle()
                .fill(
                    AngularGradient(
                        colors: [accentColor.opacity(0.4), .clear],
                        center: .center,
                        startAngle: .degrees(scanRotation),
                        endAngle: .degrees(scanRotation - 90)
                    )
                )
                .frame(width: 240 * scale, height: 240 * scale)
                .rotationEffect(.degrees(scanRotation))

            // Bearing needle + distance readout.
            ZStack {
                if hasSignal {
                    VStack {
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 16 * scale, weight: .bold))
                            .foregroundColor(accentColor)
                            .shadow(color: accentColor, radius: 8 * scale)
                            .scaleEffect(pulseScale)
                        Spacer()
                    }
                    .frame(height: 220 * scale)
                    .rotationEffect(.degrees((bearingDegrees ?? 0) - currentHeading))
                    .animation(ADATheme.spatialSpring, value: (bearingDegrees ?? 0) - currentHeading)
                }

                VStack(spacing: 2 * scale) {
                    Text(distanceMeters.map(String.init) ?? "--")
                        .font(ADATheme.displayFont(size: 38 * scale))
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: distanceMeters)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)

                    Text(hasSignal ? "METERS" : "ACQUIRING")
                        .font(ADATheme.telemetryFont(size: 10 * scale))
                        .foregroundColor(.white.opacity(0.6))
                        .tracking(2)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .glassCard(cornerRadius: diameter / 2, tint: accentColor)
        .onAppear {
            withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                scanRotation = 360
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulseScale = 1.3
            }
        }
        .onChange(of: distanceMeters) { newValue in
            handleProximityChange(newValue)
        }
    }

    private var hasSignal: Bool { distanceMeters != nil }

    private var accentColor: Color {
        if let distanceMeters, role == .runner {
            return ADATheme.dangerColor(distanceMeters: distanceMeters)
        }
        return ADATheme.accent(for: role)
    }

    private var haloOpacity: Double {
        guard let distanceMeters, role == .runner else { return 0.15 }
        return distanceMeters < 15 ? 0.35 : (distanceMeters < 50 ? 0.22 : 0.15)
    }

    private func handleProximityChange(_ distance: Int?) {
        guard role == .runner, let distance, distance < 25 else { return }
        HapticsEngine.shared.playProximityPulse(distanceMeters: distance)
        withAnimation(.easeOut(duration: 0.25)) { ringPulse = 1.08 }
        withAnimation(.easeIn(duration: 0.35).delay(0.15)) { ringPulse = 1.0 }
    }
}

// See AuthView.swift for why this is gated — #Preview needs an Xcode-only plugin.
#if !SWIFT_PACKAGE
#Preview {
    ZStack {
        ADATheme.obsidianBackground.edgesIgnoringSafeArea(.all)
        SpatialRadarView(distanceMeters: 18, bearingDegrees: 120, currentHeading: 45, role: .runner)
    }
}
#endif
