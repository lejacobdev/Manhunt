import SwiftUI

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
    static let obsidianBackgroundElevated = Color(hex: "#0C0F14")
    static let surfaceGlass = Color.white.opacity(0.08)
    static let borderGlass = Color.white.opacity(0.15)

    // MARK: Tactical accents

    static let hunterRed = TacticalPalette.hunterRed
    static let runnerGreen = TacticalPalette.runnerGreen
    static let tacticalAmber = TacticalPalette.tacticalAmber
    static let spatialCyan = TacticalPalette.spatialCyan
    static let stealthPurple = TacticalPalette.stealthPurple
    static let neutralGray = TacticalPalette.neutralGray

    static func accent(for role: PlayerRole) -> Color {
        switch role {
        case .hunter: return hunterRed
        case .runner: return runnerGreen
        case .supervisor: return spatialCyan
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

    // MARK: Motion

    /// Standard spring for spatial elements (compass needle, blips, map annotations).
    static let spatialSpring: Animation = .interpolatingSpring(stiffness: 120, damping: 14)
    /// Snappier spring for interactive controls (buttons, cards entering/leaving).
    static let controlSpring: Animation = .spring(response: 0.4, dampingFraction: 0.7)
    /// Soft spring for ambient/ephemeral state (badges, banners).
    static let ambientSpring: Animation = .spring(response: 0.55, dampingFraction: 0.8)
}

// MARK: - Glassmorphic surfaces

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = ADATheme.cardCornerRadius
    var tint: Color = .clear

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    tint.opacity(0.12)
                }
            )
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.25), .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.4), radius: 20, x: 0, y: 10)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = ADATheme.cardCornerRadius, tint: Color = .clear) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tint: tint))
    }

    /// Applies the app's obsidian backdrop, edge-to-edge.
    func obsidianBackdrop() -> some View {
        background(ADATheme.obsidianBackground.edgesIgnoringSafeArea(.all))
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ADATheme.telemetryFont(size: 14))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.7 : 1.0))
            )
            .foregroundColor(.black)
            .shadow(color: tint.opacity(configuration.isPressed ? 0.15 : 0.45), radius: configuration.isPressed ? 6 : 16, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(isLoading ? 0.6 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Secondary "ghost" button used for less-committal actions on top of glass surfaces.
struct GlassButtonStyle: ButtonStyle {
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ADATheme.telemetryFont(size: 13))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(tint.opacity(configuration.isPressed ? 0.28 : 0.16))
            .foregroundColor(tint)
            .overlay(
                RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous)
                    .stroke(tint.opacity(0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Status badge

/// The floating capsule badge used for buffs, danger levels, and connection state.
struct StatusBadge: View {
    let icon: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
            Text(text)
                .font(ADATheme.telemetryFont(size: 11))
                .tracking(0.5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.25))
        .overlay(Capsule().stroke(tint, lineWidth: 1))
        .clipShape(Capsule())
        .foregroundColor(tint)
        .shadow(color: tint.opacity(0.4), radius: 8)
        .transition(.scale.combined(with: .opacity))
    }
}
