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

    @State private var pulseScale: CGFloat = 1.0
    @State private var scanRotation: Double = 0.0
    @State private var ringPulse: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Outer glowing halo — intensifies as danger increases.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accentColor.opacity(haloOpacity), .clear],
                        center: .center,
                        startRadius: 40,
                        endRadius: 140
                    )
                )
                .frame(width: 280, height: 280)
                .scaleEffect(ringPulse)

            // Concentric radar rings & crosshair grid.
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radii: [CGFloat] = [40, 80, 120]

                for radius in radii {
                    var path = Path()
                    path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.stroke(path, with: .color(Color.white.opacity(0.12)), lineWidth: 1)
                }

                var reticlePath = Path()
                reticlePath.move(to: CGPoint(x: center.x, y: 10))
                reticlePath.addLine(to: CGPoint(x: center.x, y: size.height - 10))
                reticlePath.move(to: CGPoint(x: 10, y: center.y))
                reticlePath.addLine(to: CGPoint(x: size.width - 10, y: center.y))
                context.stroke(reticlePath, with: .color(Color.white.opacity(0.08)), lineWidth: 1)
            }
            .frame(width: 240, height: 240)

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
                .frame(width: 240, height: 240)
                .rotationEffect(.degrees(scanRotation))

            // Bearing needle + distance readout.
            ZStack {
                if hasSignal {
                    VStack {
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(accentColor)
                            .shadow(color: accentColor, radius: 8)
                            .scaleEffect(pulseScale)
                        Spacer()
                    }
                    .frame(height: 220)
                    .rotationEffect(.degrees((bearingDegrees ?? 0) - currentHeading))
                    .animation(ADATheme.spatialSpring, value: (bearingDegrees ?? 0) - currentHeading)
                }

                VStack(spacing: 2) {
                    Text(distanceMeters.map(String.init) ?? "--")
                        .font(ADATheme.displayFont(size: 38))
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: distanceMeters)

                    Text(hasSignal ? "METERS" : "ACQUIRING")
                        .font(ADATheme.telemetryFont(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                        .tracking(2)
                }
            }
        }
        .frame(width: 260, height: 260)
        .glassCard(cornerRadius: 130, tint: accentColor)
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
