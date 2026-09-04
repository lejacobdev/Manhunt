import SwiftUI

// Compiled into both the HuntingGame app target and the HuntingGameWidgets
// extension target so the Lock Screen / Dynamic Island Live Activity renders
// with the exact same tactical palette and SAFE/WARNING/CRITICAL thresholds
// as the in-app HUD.

extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let r, g, b, a: UInt64
        switch sanitized.count {
        case 6:
            (r, g, b, a) = ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF, 0xFF)
        case 8:
            (r, g, b, a) = ((value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
        default:
            (r, g, b, a) = (255, 255, 255, 255)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// This is the same palette baked into ios/xtool/icon.png — the app icon and
// every in-app surface are drawn from one designed color system rather than
// stock iOS system colors (the old #FF2D55/#30D158/etc.), so the icon in a
// SideStore listing and the HUD it opens into read as the same product.
enum TacticalPalette {
    static let obsidianBackground = Color(hex: "#090B10")
    static let hunterRed = Color(hex: "#D93A4A")
    static let runnerGreen = Color(hex: "#1AA262")
    static let tacticalAmber = Color(hex: "#F5A524")
    static let spatialCyan = Color(hex: "#49D4FF")
    static let stealthPurple = Color(hex: "#A78BFA")
    static let neutralGray = Color(hex: "#9BA1AC")

    static func dangerColor(distanceMeters: Int) -> Color {
        switch distanceMeters {
        case ..<15: return hunterRed
        case 15..<50: return tacticalAmber
        default: return runnerGreen
        }
    }

    static func dangerColor(forLevel level: String) -> Color {
        switch level {
        case "CRITICAL": return hunterRed
        case "WARNING": return tacticalAmber
        default: return runnerGreen
        }
    }

    static func dangerLabel(distanceMeters: Int) -> String {
        switch distanceMeters {
        case ..<15: return "CRITICAL"
        case 15..<50: return "WARNING"
        default: return "SAFE"
        }
    }
}
