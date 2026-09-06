import SwiftUI

/// The runner's tactical compass: a Canvas-drawn radar reticle with a rotating scan sweep,
/// one spring-loaded bearing needle per visible hunter, and a live distance readout for
/// whichever is closest. Feeds the escalating CoreHaptics proximity pulse once the nearest
/// distance drops under 25m.
struct SpatialRadarView: View {
    /// Legacy single-target fallback, used only when `hunters` is empty (e.g. a stale
    /// server or the Xcode preview below) — otherwise `hunters` is the source of truth.
    let distanceMeters: Int?
    let bearingDegrees: Double?
    var hunters: [HunterBearing] = []
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

            // One needle per visible hunter — the nearest is bigger, glowing, and pulses;
            // the rest are dim so they read as "also out there" without competing with it.
            ForEach(Array(effectiveHunters.enumerated()), id: \.element.hunterId) { index, hunter in
                let isNearest = index == 0
                VStack(spacing: 2 * scale) {
                    Image(systemName: "triangle.fill")
                        .font(.system(size: (isNearest ? 16 : 9) * scale, weight: .bold))
                        .foregroundColor(isNearest ? accentColor : .white.opacity(0.45))
                        .shadow(color: isNearest ? accentColor : .clear, radius: isNearest ? 8 * scale : 0)
                        .scaleEffect(isNearest ? pulseScale : 1.0)
                    if !isNearest {
                        // Every non-nearest hunter still gets its own distance label — the
                        // big center readout only ever shows the closest one.
                        Text("\(hunter.distanceMeters)m")
                            .font(ADATheme.telemetryFont(size: 8 * scale))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Spacer()
                }
                .frame(height: 220 * scale)
                .rotationEffect(.degrees(hunter.bearingDegrees - currentHeading))
                .animation(ADATheme.spatialSpring, value: hunter.bearingDegrees - currentHeading)
            }

            VStack(spacing: 2 * scale) {
                Text(nearestDistance.map(String.init) ?? "--")
                    .font(ADATheme.displayFont(size: 38 * scale))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: nearestDistance)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                Text(hasSignal ? "METERS" : "ACQUIRING")
                    .font(ADATheme.telemetryFont(size: 10 * scale))
                    .foregroundColor(.white.opacity(0.6))
                    .tracking(2)
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
        .onChange(of: nearestDistance) { newValue in
            handleProximityChange(newValue)
        }
    }

    /// `hunters` when the server sent any; otherwise the legacy single distance/bearing
    /// pair wrapped as a one-item list, so the rendering loop above never needs two paths.
    private var effectiveHunters: [HunterBearing] {
        if !hunters.isEmpty { return hunters }
        guard let distanceMeters, let bearingDegrees else { return [] }
        return [HunterBearing(hunterId: "nearest", username: "", distanceMeters: distanceMeters, bearingDegrees: bearingDegrees)]
    }

    private var nearestDistance: Int? { effectiveHunters.first?.distanceMeters }
    private var hasSignal: Bool { nearestDistance != nil }

    private var accentColor: Color {
        if let nearestDistance, role == .runner {
            return ADATheme.dangerColor(distanceMeters: nearestDistance)
        }
        return ADATheme.accent(for: role)
    }

    private var haloOpacity: Double {
        guard let nearestDistance, role == .runner else { return 0.15 }
        return nearestDistance < 15 ? 0.35 : (nearestDistance < 50 ? 0.22 : 0.15)
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
