import SwiftUI
import MapKit

/// How each cosmetic id looks. The server's catalog (backend/src/cosmetics/catalog.ts) decides who
/// owns what; this file only knows how to draw an id. Unknown ids fall back to the default look,
/// so a newer item never breaks an older build. Cosmetics are looks only — none of this changes
/// how a match plays.
enum CosmeticStyle {
    // MARK: Map style (only you see it)

    @available(iOS 16.0, *)
    static func mapConfiguration(_ id: String?) -> MKMapConfiguration {
        switch id {
        case "map.muted": return MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        case "map.satellite": return MKImageryMapConfiguration(elevationStyle: .realistic)
        case "map.hybrid": return MKHybridMapConfiguration(elevationStyle: .realistic)
        default: return MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
        }
    }

    // MARK: Radar skin (only you see it)

    /// The radar's accent; nil means "your role colour".
    static func radarAccent(_ id: String?) -> Color? {
        switch id {
        case "radar.ghost": return ADATheme.stealthPurple
        case "radar.arctic": return Color(hex: "#9BE7FF")
        case "radar.gold": return Color(hex: "#FFC94A")
        case "radar.mono": return .white
        case "radar.supporter": return Color(hex: "#5EF2C2")
        default: return nil
        }
    }

    // MARK: Map marker (your teammates see it)

    static func markerGlyph(_ id: String?, role: PlayerRole) -> String {
        switch id {
        case "marker.hare": return "hare.fill"
        case "marker.bolt": return "bolt.fill"
        case "marker.flame": return "flame.fill"
        case "marker.star": return "star.fill"
        case "marker.paw": return "pawprint.fill"
        default: return role == .hunter ? "figure.run" : "figure.walk"
        }
    }

    // MARK: Banner (everyone sees it)

    static func bannerColors(_ id: String?) -> [Color] {
        switch id {
        case "banner.royal": return [Color(hex: "#7C5CFF"), Color(hex: "#3B2A8F")]
        case "banner.toxic": return [Color(hex: "#9DFF3C"), Color(hex: "#1F8A3A")]
        case "banner.ember": return [ADATheme.hunterRed, ADATheme.tacticalAmber]
        case "banner.ice": return [.white, ADATheme.spatialCyan]
        case "banner.aurora": return [ADATheme.runnerGreen, ADATheme.stealthPurple]
        case "banner.supporter": return [Color(hex: "#FFD66B"), Color(hex: "#C98A2B")]
        default: return [ADATheme.spatialCyan, ADATheme.spatialCyan.opacity(0.5)]
        }
    }

    /// The single colour a glass card tints with for this banner.
    static func bannerTint(_ id: String?) -> Color { bannerColors(id).first ?? ADATheme.spatialCyan }

    // MARK: Badge (everyone sees it)

    static func badge(_ id: String?) -> (title: String, icon: String, tint: Color)? {
        switch id {
        case "badge.tracker": return ("TRACKER", "scope", ADATheme.hunterRedText)
        case "badge.marathon": return ("MARATHON", "figure.run", ADATheme.runnerGreen)
        case "badge.veteran": return ("VETERAN", "shield.lefthalf.filled", ADATheme.spatialCyan)
        case "badge.supporter": return ("SUPPORTER", "heart.fill", Color(hex: "#FFD66B"))
        default: return nil
        }
    }

    /// An SF Symbol that previews an item in the store.
    static func previewIcon(_ category: String, id: String) -> String {
        switch category {
        case "mapStyle": return id == "map.satellite" || id == "map.hybrid" ? "globe.europe.africa.fill" : "map.fill"
        case "radarSkin": return "dot.radiowaves.left.and.right"
        case "marker": return markerGlyph(id, role: .runner)
        case "banner": return "rectangle.fill"
        default: return badge(id)?.icon ?? "circle.slash"
        }
    }
}

/// A small badge pill beside a player's name.
struct CosmeticBadgeView: View {
    let id: String?
    var body: some View {
        if let badge = CosmeticStyle.badge(id) {
            HStack(spacing: 4) {
                Image(systemName: badge.icon).tacticalFont(.symbol, size: 9, weight: .bold)
                Text(badge.title).tacticalFont(.telemetry, size: 9)
            }
            .foregroundColor(badge.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(badge.tint.opacity(0.14)))
            .overlay(Capsule().stroke(badge.tint.opacity(0.35), lineWidth: 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(badge.title.capitalized) badge")
        }
    }
}
