import SwiftUI
import UIKit

// Color(hex:) lives in Shared/TacticalPalette.swift, which is compiled into
// this target too — see that file for the definition.

// MARK: - Design tokens

/// The Apple Design Award-grade visual language for HuntingGame: deep OLED
/// blacks, neon tactical signal colors, and a rounded/monospaced type pairing
/// (display numerals in SF Pro Rounded, telemetry in SF Mono) that reads as
/// equal parts military HUD and native iOS polish. Every value here is a
/// system-provided font/design variant — no custom font files are bundled.
enum ADATheme {
    // MARK: Surfaces

    static let obsidianBackground = TacticalPalette.obsidianBackground
    static let obsidianBackgroundElevated = Color(hex: "#1A1F2E")
    static let surfaceGlass = Color.white.opacity(0.08)
    static let borderGlass = Color.white.opacity(0.15)

    // MARK: Tactical accents

    static let hunterRed = TacticalPalette.hunterRed
    /// Hunter red for text and small icons. The brand red is only 3.4:1 against the glass cards;
    /// this lighter shade is 5.6:1 and still unmistakably the hunters' colour.
    static let hunterRedText = Color(hex: "#FF6B79")
    static let runnerGreen = TacticalPalette.runnerGreen
    static let tacticalAmber = TacticalPalette.tacticalAmber
    static let spatialCyan = TacticalPalette.spatialCyan
    static let stealthPurple = TacticalPalette.stealthPurple
    static let neutralGray = TacticalPalette.neutralGray

    static func accent(for role: PlayerRole) -> Color {
        switch role {
        case .hunter: return hunterRed
        case .runner: return runnerGreen
        case .spectator: return neutralGray
        }
    }

    static func accent(for powerUp: PowerUpType) -> Color {
        switch powerUp {
        case .invisibility: return stealthPurple
        case .ghostDecoy: return spatialCyan
        case .empJammer: return tacticalAmber
        case .thermalVision: return hunterRed
        case .adrenaline: return runnerGreen
        case .safeZoneFlare: return tacticalAmber
        }
    }

    /// SAFE / WARNING / CRITICAL proximity color ramp shared by the HUD and the Live Activity.
    static func dangerColor(distanceMeters: Int) -> Color {
        TacticalPalette.dangerColor(distanceMeters: distanceMeters)
    }

    static func dangerLabel(distanceMeters: Int) -> String {
        TacticalPalette.dangerLabel(distanceMeters: distanceMeters)
    }

    // MARK: Typography

    static func displayFont(size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .rounded)
    }

    static func telemetryFont(size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }

    static func uiFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    // MARK: Geometry

    static let cardCornerRadius: CGFloat = 24
    static let controlCornerRadius: CGFloat = 16
    static let sheetCornerRadius: CGFloat = 32
    /// Cap for forms and HUD panel columns — see `View.adaptiveContentWidth()`.
    static let maxContentWidth: CGFloat = 480
    /// Fixed width for a side-dock HUD panel (GameView's bottom dock) — narrow
    /// enough that one can sit on each side of the map without meeting in the middle.
    static let dockPanelWidth: CGFloat = 150
    /// Wider cap for GameView's own top bar + bottom dock column — those need more
    /// room than a plain form (two side docks plus the power-up tray between them),
    /// so they use this instead of `maxContentWidth`.
    static let dockContentWidth: CGFloat = 900

    // MARK: Motion

    /// Standard spring for spatial elements (compass needle, blips, map annotations).
    static let spatialSpring: Animation = .interpolatingSpring(stiffness: 120, damping: 14)
    /// Snappier spring for interactive controls (buttons, cards entering/leaving).
    static let controlSpring: Animation = .spring(response: 0.4, dampingFraction: 0.7)
    /// Soft spring for ambient/ephemeral state (badges, banners).
    static let ambientSpring: Animation = .spring(response: 0.55, dampingFraction: 0.8)
}

// MARK: - Glass surfaces
//
// The material itself lives in Glass.swift: real Liquid Glass on iOS 26+, painted glass below.

extension View {
    /// The app's standard card: one glass surface in a rounded rectangle. A tint here is a hint
    /// of the accent; pass `strength: .strong` only for role identity or danger.
    func glassCard(
        cornerRadius: CGFloat = ADATheme.cardCornerRadius,
        tint: Color = .clear,
        strength: GlassTintStrength = .subtle
    ) -> some View {
        tacticalGlass(cornerRadius: cornerRadius, tint: tint == .clear ? nil : tint, strength: strength)
    }

    /// Applies the app's obsidian backdrop, edge-to-edge.
    func obsidianBackdrop() -> some View {
        background(ADATheme.obsidianBackground.edgesIgnoringSafeArea(.all))
    }

    /// Caps a form/HUD content column at a comfortable width and centers it. A no-op on
    /// iPhone (every device width is already under the cap), but keeps forms and the
    /// live-match HUD panels from stretching edge-to-edge across an iPad's much wider
    /// screen — full-bleed only makes sense for the map itself, not the controls on it.
    func adaptiveContentWidth(_ maxWidth: CGFloat = ADATheme.maxContentWidth) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

extension Color {
    /// Linear RGBA blend between two colors — used to crossfade the shared radar backdrop's
    /// tint continuously as the swipeable pager's drag progresses between two tabs' accent
    /// colors, rather than jump-cutting once a swipe settles. SwiftUI's own `Color` has no
    /// built-in interpolation, so this goes through UIColor's component accessors.
    static func interpolate(from: Color, to: Color, fraction: Double) -> Color {
        let f = min(max(fraction, 0), 1)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        UIColor(from).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(to).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            red: Double(r1 + (r2 - r1) * f),
            green: Double(g1 + (g2 - g1) * f),
            blue: Double(b1 + (b2 - b1) * f),
            opacity: Double(a1 + (a2 - a1) * f)
        )
    }
}

// MARK: - Button styles

/// Tactile press-scale used on every tappable tactical control (power-ups, blips, chips).
struct ScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.93

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Full-width primary call-to-action with a glowing accent fill, used for the app's
/// major commitments (sign in, create game, confirm catch).
struct GlowButtonStyle: ButtonStyle {
    var tint: Color
    var isLoading: Bool = false
    /// Keep the neon glow for the one primary action on a screen; secondary uses turn it off.
    var glow: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tacticalFont(.telemetry, size: 14)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .contentShape(RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous))
            .modifier(TacticalButtonChrome(kind: .prominent, tint: tint, isPressed: configuration.isPressed, glow: glow))
            .foregroundColor(.black)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(isLoading ? 0.6 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Secondary "ghost" button used for less-committal actions. Named so it never collides with
/// SwiftUI 26's own `GlassButtonStyle`, which is what `.buttonStyle(.glass)` returns.
struct TacticalGhostButtonStyle: ButtonStyle {
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tacticalFont(.telemetry, size: 13)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous))
            .modifier(TacticalButtonChrome(kind: .ghost, tint: tint, isPressed: configuration.isPressed))
            .foregroundColor(tint)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Status badge

/// The floating capsule badge used for buffs, danger levels, and connection state. On real glass
/// the accent lives on the icon and text; the capsule only carries a faint tint of it.
struct StatusBadge: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .tacticalFont(.symbol, size: 12, weight: .bold)
            Text(text)
                .tacticalFont(.telemetry, size: 11)
                .tracking(0.5)
                .tacticalNumericTransition()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundColor(tint)
        .tacticalGlass(in: Capsule(), tint: tint)
        .shadow(color: tint.opacity(0.3), radius: 8)
        .transition(.scale.combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}
