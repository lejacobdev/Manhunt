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

enum TacticalPalette {
    static let obsidianBackground = Color(hex: "#05070A")
    static let hunterRed = Color(hex: "#FF2D55")
    static let runnerGreen = Color(hex: "#30D158")
    static let tacticalAmber = Color(hex: "#FF9F0A")
    static let spatialCyan = Color(hex: "#64D2FF")
    static let stealthPurple = Color(hex: "#BF5AF2")
    static let neutralGray = Color(hex: "#8E8E93")

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
