import SwiftUI

// MARK: - The glass layer
//
// The one file in the app allowed to contain `#available(iOS 26, *)` for glass. Screens never
// call `glassEffect` directly: they call `tacticalGlass` (or `glassCard`, which forwards here),
// `TacticalGlassContainer` and `tacticalGlassID`. On iOS 26 and later those render Apple's real
// Liquid Glass; below it they render the painted glass the app shipped with in 1.0, so a player
// on an older iPhone sees no change at all. If a later iOS changes glass again, this is the only
// file to touch.
//
// Rules this file enforces so call sites don't have to remember them:
// - Glass never sits on glass. Anything drawn inside a glass surface is told so through the
//   environment and renders as a plain, faintly filled shape instead of a second layer of glass.
// - Real glass draws its own edge highlight and depth, so the painted sheen, gradient stroke and
//   drop shadow exist only in the fallback.
// - Tints stay faint unless the caller asks for a strong one (role identity, danger, the one
//   primary action on a screen); on real glass a full-strength tint on every card reads as soup.
// - Reduce Transparency is honoured by the system for real glass; the fallback switches to a
//   solid elevated surface.

/// How strongly a glass surface carries its tint.
enum GlassTintStrength {
    /// A hint of the accent — the default for cards and panels.
    case subtle
    /// The surface *is* the colour: role identity, danger states, the screen's primary action.
    case strong

    var glassOpacity: Double {
        switch self {
        case .subtle: return 0.16
        case .strong: return 0.42
        }
    }

    var legacyOpacity: Double {
        switch self {
        case .subtle: return 0.12
        case .strong: return 0.28
        }
    }
}

private struct InsideTacticalGlassKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True for anything drawn inside a glass surface — nested surfaces read it and render
    /// plain instead of stacking a second layer of glass.
    var isInsideTacticalGlass: Bool {
        get { self[InsideTacticalGlassKey.self] }
        set { self[InsideTacticalGlassKey.self] = newValue }
    }
}

extension View {
    /// Liquid Glass in `shape` on iOS 26+, the app's painted glass below.
    func tacticalGlass<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        strength: GlassTintStrength = .subtle,
        interactive: Bool = false
    ) -> some View {
        modifier(TacticalGlassModifier(shape: AnyShape(shape), tint: tint, strength: strength, interactive: interactive))
    }

    /// Liquid Glass in a continuous rounded rectangle — the app's standard card shape.
    func tacticalGlass(
        cornerRadius: CGFloat = ADATheme.cardCornerRadius,
        tint: Color? = nil,
        strength: GlassTintStrength = .subtle,
        interactive: Bool = false
    ) -> some View {
        tacticalGlass(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            strength: strength,
            interactive: interactive
        )
    }

    /// Ties a glass surface to an identity inside a `TacticalGlassContainer`, so that when one
    /// surface appears or disappears it morphs out of, or into, its neighbour. No-op below iOS 26.
    @ViewBuilder
    func tacticalGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// Merges this surface with every other surface carrying the same union id into one shape
    /// (the HUD top bar and its badges). No-op below iOS 26.
    @ViewBuilder
    func tacticalGlassUnion<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            glassEffectUnion(id: id, namespace: namespace)
        } else {
            self
        }
    }
}

extension AnyTransition {
    /// The transition for a glass surface that lives in a `TacticalGlassContainer`. On iOS 26 the
    /// container morphs the glass itself, so a view-level move or fade on top of that would
    /// fight it; below iOS 26 there is no morph, so `fallback` runs instead.
    static func tacticalGlassMorph(fallback: AnyTransition) -> AnyTransition {
        if #available(iOS 26.0, *) {
            return .opacity
        }
        return fallback
    }
}

/// Groups glass surfaces that live together — the tab bar, the HUD dock, the top-bar badges, the
/// power-up tray — so they render as one material and can merge and split. A plain group below
/// iOS 26.
struct TacticalGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

private struct TacticalGlassModifier: ViewModifier {
    let shape: AnyShape
    let tint: Color?
    let strength: GlassTintStrength
    let interactive: Bool

    @Environment(\.isInsideTacticalGlass) private var isInsideGlass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if isInsideGlass {
            // Glass on glass goes muddy: inside another surface, draw a quiet inset instead.
            content
                .background(
                    shape.fill((tint ?? .white).opacity(tint == nil ? 0.06 : strength.legacyOpacity * 0.8))
                )
                .overlay(shape.stroke((tint ?? .white).opacity(0.12), lineWidth: 0.5))
                .clipShape(shape)
        } else if #available(iOS 26.0, *) {
            content
                .environment(\.isInsideTacticalGlass, true)
                .glassEffect(glass, in: shape)
                .environment(\.colorScheme, .dark)
        } else {
            content
                .environment(\.isInsideTacticalGlass, true)
                .modifier(LegacyGlassSurface(shape: shape, tint: tint, strength: strength, solid: reduceTransparency))
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(strength.glassOpacity)) }
        return glass.interactive(interactive)
    }
}

/// The painted glass the app shipped with in 1.0, kept as the pre-iOS 26 fallback.
private struct LegacyGlassSurface: ViewModifier {
    let shape: AnyShape
    let tint: Color?
    let strength: GlassTintStrength
    /// Reduce Transparency: a solid elevated surface rather than a blur.
    let solid: Bool

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    if solid {
                        shape.fill(ADATheme.obsidianBackgroundElevated)
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                    if let tint { shape.fill(tint.opacity(strength.legacyOpacity)) }
                }
            )
            .environment(\.colorScheme, .dark)
            .clipShape(shape)
            .overlay(
                // Specular sheen along the top edge, as if light catches a curved glass surface —
                // the same cue as the app icon's sheen.
                LinearGradient(colors: [.white.opacity(solid ? 0.06 : 0.18), .white.opacity(0)], startPoint: .top, endPoint: .center)
                    .clipShape(shape)
                    .allowsHitTesting(false)
            )
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
            )
            .shadow(color: Color.black.opacity(0.4), radius: 20, x: 0, y: 10)
    }
}

// MARK: - Button chrome

/// The material behind the app's two custom button styles, kept here so the styles themselves
/// carry no availability checks.
struct TacticalButtonChrome: ViewModifier {
    enum Kind { case prominent, ghost }

    let kind: Kind
    let tint: Color
    let isPressed: Bool
    /// The neon glow is the brand: used once per screen it reads premium, everywhere it reads loud.
    var glow: Bool = true

    @Environment(\.isInsideTacticalGlass) private var isInsideGlass

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ADATheme.controlCornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !isInsideGlass {
            switch kind {
            case .prominent:
                content
                    .glassEffect(.regular.tint(tint.opacity(isPressed ? 0.75 : 0.92)).interactive(), in: shape)
                    .shadow(color: tint.opacity(glow ? (isPressed ? 0.12 : 0.32) : 0), radius: isPressed ? 6 : 14, x: 0, y: 6)
            case .ghost:
                content
                    .glassEffect(.regular.interactive(), in: shape)
                    .environment(\.colorScheme, .dark)
            }
        } else {
            switch kind {
            case .prominent:
                content
                    .background(shape.fill(tint.opacity(isPressed ? 0.7 : 1.0)))
                    .shadow(color: tint.opacity(glow ? (isPressed ? 0.15 : 0.45) : 0), radius: isPressed ? 6 : 16, x: 0, y: 8)
            case .ghost:
                content
                    .background(tint.opacity(isPressed ? 0.28 : 0.16))
                    .overlay(shape.stroke(tint.opacity(0.5), lineWidth: 1))
                    .clipShape(shape)
            }
        }
    }
}

// MARK: - Numeric text

extension View {
    /// Timers and distances tick from one value to the next instead of flickering (iOS 17+).
    @ViewBuilder
    func tacticalNumericTransition(countsDown: Bool = false) -> some View {
        if #available(iOS 17.0, *) {
            contentTransition(.numericText(countsDown: countsDown))
        } else {
            self
        }
    }
}

// MARK: - Reduce Motion

extension View {
    /// `transition`, except that with Reduce Motion on it is a plain fade: no zooming, sliding or
    /// springing panels for anyone who finds that motion uncomfortable.
    func tacticalTransition(_ transition: AnyTransition) -> some View {
        modifier(ReduceMotionTransition(transition: transition))
    }
}

private struct ReduceMotionTransition: ViewModifier {
    let transition: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : transition)
    }
}
