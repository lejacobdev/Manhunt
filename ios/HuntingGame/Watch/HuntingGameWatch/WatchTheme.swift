import SwiftUI

// The Watch's design system: the iPhone app's obsidian / glow / telemetry language, sized for a
// wrist. Everything on screen is built from the handful of pieces below, so the pages read as one
// product instead of a stack of one-off layouts.

enum WT {
    static let bg = TacticalPalette.obsidianBackground
    static let red = TacticalPalette.hunterRed
    static let green = TacticalPalette.runnerGreen
    static let amber = TacticalPalette.tacticalAmber
    static let cyan = TacticalPalette.spatialCyan
    static let purple = TacticalPalette.stealthPurple
    static let gray = TacticalPalette.neutralGray

    /// The colour a role wears everywhere: runners green, hunters red, spectators cyan.
    static func accent(forRole role: String) -> Color {
        switch role {
        case "HUNTER": return red
        case "RUNNER": return green
        default: return cyan
        }
    }

    /// Closer = more intense, for both roles — the same rule the iPhone radar uses.
    static func danger(_ distanceMeters: Int?) -> Color {
        guard let distanceMeters else { return gray }
        return TacticalPalette.dangerColor(distanceMeters: distanceMeters)
    }
}

extension Font {
    /// Small tracked-out telemetry labels ("METERS", "FREE").
    static func wtMono(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Big friendly numbers and headlines.
    static func wtRounded(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// "3:07" for a number of seconds.
func wtClock(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

extension WatchGameSnapshot {
    /// When a countdown that read `seconds` at the moment the phone built this snapshot runs out.
    /// Anchoring to the phone's own timestamp (rather than "now") is what lets the Watch tick a
    /// smooth per-second countdown between snapshots without drifting each time a new one lands.
    func deadline(after seconds: Int) -> Date {
        updatedAt.addingTimeInterval(TimeInterval(max(0, seconds)))
    }

    /// The players to draw on the radar: the 1.0.1 list, or — from an older phone that sent none —
    /// the single nearest reading it did send.
    var radarBlips: [WatchBlip] {
        if !blips.isEmpty { return blips.sorted { $0.distanceMeters < $1.distanceMeters } }
        return nearestBlip.map { [$0] } ?? []
    }
}

// MARK: - Background

/// Obsidian with a soft glow of the page's accent colour pooled at the top — the Watch cousin of
/// the iPhone's radar-sweep backdrop.
struct WTBackground: View {
    var accent: Color
    var strength: Double = 0.30
    @Environment(\.isLuminanceReduced) private var isDimmed

    var body: some View {
        ZStack {
            WT.bg
            if !isDimmed {
                RadialGradient(
                    colors: [accent.opacity(strength), .clear],
                    center: .top, startRadius: 0, endRadius: 210
                )
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Surfaces

/// A quiet rounded panel with a hairline in the same tint.
struct WTCard: ViewModifier {
    var tint: Color
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(tint.opacity(0.24), lineWidth: 1))
    }
}

extension View {
    func wtCard(tint: Color = .white, radius: CGFloat = 16) -> some View {
        modifier(WTCard(tint: tint, radius: radius))
    }
}

struct WTButtonStyle: ButtonStyle {
    var tint: Color
    /// Filled (the main action) or an outline (the alternative).
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.wtRounded(13))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(prominent ? Color.black : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(prominent ? tint : tint.opacity(0.14)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(prominent ? 0 : 0.5), lineWidth: 1)
            )
            .shadow(color: prominent ? tint.opacity(0.4) : .clear, radius: 7)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Small pieces

/// A tracked, monospaced caption — "METERS", "FREE", "REQUEST CATCH".
struct WTLabel: View {
    let text: String
    var color: Color = WT.gray
    var size: CGFloat = 9

    init(_ text: String, color: Color = WT.gray, size: CGFloat = 9) {
        self.text = text
        self.color = color
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(.wtMono(size))
            .tracking(1.2)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// A symbol in a softly glowing round badge — the one icon treatment used everywhere, so the
/// icons all read as a set.
struct WTIconBadge: View {
    let symbol: String
    var tint: Color
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            Circle().strokeBorder(tint.opacity(0.42), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

/// Role name with its icon, in the role's colour.
struct WTRolePill: View {
    let role: String

    private var symbol: String {
        switch role {
        case "HUNTER": return "scope"
        case "RUNNER": return "figure.run"
        default: return "eye.fill"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(role.isEmpty ? "—" : role).font(.wtMono(10)).tracking(0.8)
        }
        .foregroundStyle(WT.accent(forRole: role))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(WT.accent(forRole: role).opacity(0.16)))
        .overlay(Capsule().strokeBorder(WT.accent(forRole: role).opacity(0.4), lineWidth: 1))
    }
}

/// Hearts, with any beyond the normal maximum (bonus hearts) in green.
struct WTHearts: View {
    let hearts: Int
    let maxHearts: Int
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<max(hearts, maxHearts), id: \.self) { index in
                Image(systemName: index < hearts ? "heart.fill" : "heart")
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(index < hearts ? (index >= maxHearts ? WT.green : WT.red) : Color.white.opacity(0.22))
                    .shadow(color: index < hearts ? WT.red.opacity(0.55) : .clear, radius: 3)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: hearts)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(hearts) of \(maxHearts) hearts")
    }
}

/// A live mm:ss countdown to a fixed moment (it ticks by itself between snapshots).
struct WTCountdown: View {
    let until: Date
    var font: Font = .wtRounded(20)

    var body: some View {
        Group {
            if until > Date() {
                Text(timerInterval: Date()...until, countsDown: true, showsHours: false)
            } else {
                Text("0:00")
            }
        }
        .font(font)
        .monospacedDigit()
    }
}

/// A full-width status strip — "OUTSIDE ZONE", "FREEING PRISONERS" — that breathes gently so it
/// reads as live without being loud.
struct WTBanner: View {
    let symbol: String
    let text: String
    var detail: Date? = nil
    let tint: Color
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
            Text(text)
                .font(.wtMono(9))
                .tracking(0.6)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail {
                WTCountdown(until: detail, font: .wtRounded(15)).foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .wtCard(tint: tint, radius: 12)
        .opacity(breathe ? 1 : 0.8)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

// MARK: - Power-ups

/// How each power-up looks on the Watch. Icons match the iPhone app's.
struct WatchGear {
    let raw: String
    let name: String
    let symbol: String
    let tint: Color
    let durationSeconds: Int

    static func info(for raw: String) -> WatchGear {
        switch raw {
        case "INVISIBILITY_10MIN": return WatchGear(raw: raw, name: "Invisible", symbol: "eye.slash.fill", tint: WT.purple, durationSeconds: 60)
        case "GHOST_DECOY": return WatchGear(raw: raw, name: "Decoy", symbol: "person.3.sequence.fill", tint: WT.cyan, durationSeconds: 180)
        case "EMP_JAMMER": return WatchGear(raw: raw, name: "EMP", symbol: "bolt.slash.fill", tint: WT.amber, durationSeconds: 60)
        case "THERMAL_VISION": return WatchGear(raw: raw, name: "Thermal", symbol: "eye.trianglebadge.exclamationmark", tint: WT.red, durationSeconds: 45)
        case "ADRENALINE": return WatchGear(raw: raw, name: "Adrenaline", symbol: "bolt.heart.fill", tint: WT.green, durationSeconds: 90)
        case "SAFE_ZONE_FLARE": return WatchGear(raw: raw, name: "Flare", symbol: "flame.fill", tint: WT.amber, durationSeconds: 90)
        default:
            return WatchGear(raw: raw, name: raw.replacingOccurrences(of: "_", with: " ").capitalized, symbol: "sparkles", tint: WT.gray, durationSeconds: 0)
        }
    }
}
