import SwiftUI
import UIKit

// MARK: - Dynamic Type without changing the default look
//
// Every text site in the app was written with a fixed point size (`ADATheme.telemetryFont(size:)`
// and friends), which never scales. Remapping each one to a text style would shift every size at
// the default setting, so instead `tacticalFont` keeps the exact point size and scales it the way
// UIKit scales body text: at the default Dynamic Type size nothing moves; at larger settings
// everything grows. Places that must stay compact — the live match HUD, the tab bar — cap the
// range with SwiftUI's own `.dynamicTypeSize(...)` rather than opting out.

/// Which of the app's type families a text site uses.
enum TacticalFontRole {
    /// SF Pro Rounded, black by default — big numerals and titles.
    case display
    /// SF Mono, bold by default — labels, ids, timers, distances.
    case telemetry
    /// SF Pro, semibold by default — ordinary interface text.
    case ui
    /// SF Pro for SF Symbols, semibold by default.
    case symbol
    /// SF Pro Rounded at any weight.
    case rounded
    /// SF Mono at any weight.
    case mono

    var design: Font.Design {
        switch self {
        case .display, .rounded: return .rounded
        case .telemetry, .mono: return .monospaced
        case .ui, .symbol: return .default
        }
    }

    var defaultWeight: Font.Weight {
        switch self {
        case .display: return .black
        case .telemetry: return .bold
        case .ui, .symbol, .rounded, .mono: return .semibold
        }
    }
}

extension View {
    /// The app's font at `size` points, scaled with the reader's Dynamic Type setting.
    func tacticalFont(_ role: TacticalFontRole, size: CGFloat, weight: Font.Weight? = nil) -> some View {
        modifier(TacticalFontModifier(role: role, size: size, weight: weight ?? role.defaultWeight))
    }
}

private struct TacticalFontModifier: ViewModifier {
    let role: TacticalFontRole
    let size: CGFloat
    let weight: Font.Weight

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(.system(size: TacticalTypeScale.scaled(size, for: dynamicTypeSize), weight: weight, design: role.design))
    }
}

enum TacticalTypeScale {
    /// `size` scaled exactly as UIKit scales body text at `dynamicTypeSize`; unchanged at `.large`,
    /// the system default.
    static func scaled(_ size: CGFloat, for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: category(for: dynamicTypeSize))
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: size, compatibleWith: traits)
    }

    private static func category(for size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}
