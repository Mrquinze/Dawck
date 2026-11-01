import SwiftUI
import AppKit

/// The blurred substrate every custom-glass surface is built on. These map onto
/// `NSVisualEffectView.Material`, but only the ones that actually read as
/// *glass* behind a floating panel are offered — `.titlebar`, `.sheet` and
/// friends are tuned for surfaces that sit inside a window and look flat and
/// muddy when a dock floats them over a desktop picture.
enum GlassSubstrate: String, Codable, CaseIterable, Identifiable {
    case hud, popover, menu, sidebar, fullScreenUI, underWindow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hud: return "HUD"
        case .popover: return "Popover"
        case .menu: return "Menu"
        case .sidebar: return "Sidebar"
        case .fullScreenUI: return "Full Screen"
        case .underWindow: return "Under Window"
        }
    }

    var material: NSVisualEffectView.Material {
        switch self {
        case .hud: return .hudWindow
        case .popover: return .popover
        case .menu: return .menu
        case .sidebar: return .sidebar
        case .fullScreenUI: return .fullScreenUI
        case .underWindow: return .underWindowBackground
        }
    }
}

/// How the theme resolves light vs. dark.
enum GlassAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Always Light"
        case .dark: return "Always Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .vibrantLight)
        case .dark: return NSAppearance(named: .vibrantDark)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// What the plate behind the tiles is made of.
///
/// This is the same split Goorgle makes between its *Gradient* and *Liquid
/// Glass* looks, with Dawck's layered glass as a third, fully tunable option:
/// the theme decides how a surface is *painted*; the palette decides what it is
/// painted with.
enum ThemeFillStyle: String, Codable, CaseIterable, Identifiable {
    /// Dawck's own layered glass: blurred substrate, tint, depth, edge lensing,
    /// a pointer-tracking highlight, grain and a rim light. Every layer is a knob.
    case glass
    /// A palette painted straight onto the plate, optionally translucent.
    case gradient
    /// Apple's own Liquid Glass (macOS 26+). It draws its own edge and
    /// refraction, so the optics controls don't apply to it.
    case native

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glass: return "Custom Glass"
        case .gradient: return "Gradient"
        case .native: return "Liquid Glass"
        }
    }

    var symbol: String {
        switch self {
        case .glass: return "sparkles"
        case .gradient: return "paintpalette"
        case .native: return "drop.halffull"
        }
    }
}

enum NativeGlassVariant: String, Codable, CaseIterable, Identifiable {
    case regular, clear

    var id: String { rawValue }
    var label: String { self == .regular ? "Frosted" : "Clear" }
}

/// Whether text and glyphs drawn on the plate are chosen for contrast or forced.
///
/// Auto works from luminance, which is right nearly always — but a gradient
/// that runs from near-white to near-black has no single right answer, so the
/// override exists for the cases the math can't win.
enum TextColorMode: String, Codable, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// The backing shape behind action, widget, group, and tray tiles.
enum TileShape: String, Codable, CaseIterable, Identifiable {
    case squircle, rounded, circle, capsule, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .squircle: return "Squircle"
        case .rounded: return "Rounded"
        case .circle: return "Circle"
        case .capsule: return "Capsule"
        case .none: return "No Backing"
        }
    }

    /// Corner radius for a tile of `size`, as the shape's defining measure.
    func cornerRadius(for size: CGFloat) -> CGFloat {
        switch self {
        case .squircle: return size * 0.24
        case .rounded: return size * 0.12
        case .circle, .capsule: return size / 2
        case .none: return 0
        }
    }

    var style: RoundedCornerStyle {
        self == .rounded ? .circular : .continuous
    }
}

/// Every knob that shapes a dock surface. Persisted as JSON.
///
/// Decoding is deliberately forgiving: every field falls back to its default
/// when missing or malformed, so a theme saved by an older (or newer) build
/// loads instead of vanishing, and a hand-edited profile with one wrong value
/// loses that value rather than the whole theme.
struct GlassTheme: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Custom"

    // MARK: Fill

    var fillStyle: ThemeFillStyle = .glass
    var nativeVariant: NativeGlassVariant = .regular
    /// Native glass can react to the pointer (macOS 27 adds this to AppKit's
    /// glass view; on 26 it is simply static).
    var nativeInteractive: Bool = true
    /// Lets the macOS 27 Liquid Glass transparency slider also drive the
    /// custom glass, so a Dawck dock sits in the same family as the real Dock.
    var followsSystemGlass: Bool = true

    // MARK: Substrate (custom glass)

    var substrate: GlassSubstrate = .hud
    var appearance: GlassAppearance = .system

    /// Opacity of the whole surface, substrate included. Below ~0.2 the glass
    /// reads as a floating set of icons with no panel at all, which is a
    /// legitimate look, so the floor is left low.
    var translucency: Double = 0.92

    // MARK: Palette

    var tint: CodableColor = CodableColor(red: 0.42, green: 0.58, blue: 0.96, alpha: 1)
    /// How strongly the palette washes over the substrate. 0 is pure system blur.
    var tintIntensity: Double = 0.18
    /// Blends more than one stop across the surface so the glass shifts colour
    /// corner to corner instead of sitting on one flat wash.
    var usesGradientTint: Bool = true
    var secondaryTint: CodableColor = CodableColor(red: 0.86, green: 0.44, blue: 0.94, alpha: 1)
    /// Stops between `tint` and `secondaryTint`, so a palette can have up to
    /// five colours (Goorgle's limit) without the older two-colour fields moving.
    var midStops: [CodableColor] = []
    /// Degrees clockwise from straight down: 0 = ↓, 45 = ↘ (the classic look),
    /// 90 = →, 180 = ↑.
    var tintAngle: Double = 45
    var textColorMode: TextColorMode = .auto

    // MARK: Optics

    /// The bright bloom that tracks the pointer. This is the single most
    /// "liquid" cue — a static highlight reads as plastic.
    var specularIntensity: Double = 0.5
    /// Radius of that bloom as a fraction of the surface's short edge.
    var specularSpread: Double = 0.9
    /// Rim light around the edge: thin bright stroke, brighter where light
    /// would catch (top-leading) and dimmer opposite.
    var rimIntensity: Double = 0.55
    var rimWidth: Double = 1.0
    /// Fakes the thickness of a real pane: content near the border is pulled
    /// brighter as if bent through the edge of the glass.
    var lensing: Double = 0.45
    /// Frosted grain. Small amounts kill the "flat vector" look; large
    /// amounts read as etched glass.
    var grain: Double = 0.12
    /// Vertical light falloff — top catches more light than the bottom.
    var depth: Double = 0.35

    // MARK: Colour play

    /// The rim and lensing highlights are white by default, which reads as
    /// plain daylight. Tinting them is what makes a theme look lit by something.
    var rimColor: CodableColor = CodableColor(red: 1, green: 1, blue: 1, alpha: 1)
    /// An outer bloom around the whole panel, in its own colour.
    var glowColor: CodableColor = CodableColor(red: 0.42, green: 0.58, blue: 0.96, alpha: 1)
    var glowIntensity: Double = 0
    /// Seconds for the tint to travel once around the hue wheel. 0 holds it
    /// still. Slow values (60s+) read as the light changing, not as animation.
    var tintCycleSeconds: Double = 0
    /// Shadows are rarely literally black under coloured light.
    var shadowColor: CodableColor = CodableColor(red: 0, green: 0, blue: 0, alpha: 1)
    /// 0 renders icons greyscale, 1 leaves them alone, above 1 pushes them.
    var iconSaturation: Double = 1
    var tileShape: TileShape = .squircle
    var tileBackingOpacity: Double = 0.08

    // MARK: Geometry

    var cornerRadius: Double = 22
    /// Squircle (continuous) vs. plain circular corners.
    var continuousCorners: Bool = true
    /// Fully rounded ends, whatever size the plate ends up — Goorgle's pill.
    var capsule: Bool = false
    var padding: Double = 10

    // MARK: Elevation

    var shadowRadius: Double = 18
    var shadowOpacity: Double = 0.32
    var shadowYOffset: Double = 6

    init() {}

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, fillStyle, nativeVariant, nativeInteractive, followsSystemGlass,
             substrate, appearance, translucency,
             tint, tintIntensity, usesGradientTint, secondaryTint, midStops, tintAngle, textColorMode,
             specularIntensity, specularSpread, rimIntensity, rimWidth, lensing, grain, depth,
             rimColor, glowColor, glowIntensity, tintCycleSeconds, shadowColor, iconSaturation,
             tileShape, tileBackingOpacity,
             cornerRadius, continuousCorners, capsule, padding,
             shadowRadius, shadowOpacity, shadowYOffset,
             usesSystemGlass // legacy (2.5): read to migrate, still written for rollback
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GlassTheme()
        id = c.value(.id, UUID())
        name = c.value(.name, d.name)

        // 2.5 stored "use Apple's glass" as a boolean; it maps onto the native fill.
        let legacyNative: Bool = c.value(.usesSystemGlass, false)
        let storedFill: ThemeFillStyle? = try? c.decodeIfPresent(ThemeFillStyle.self, forKey: .fillStyle)
        fillStyle = storedFill ?? (legacyNative ? .native : .glass)
        nativeVariant = c.value(.nativeVariant, d.nativeVariant)
        nativeInteractive = c.value(.nativeInteractive, d.nativeInteractive)
        followsSystemGlass = c.value(.followsSystemGlass, d.followsSystemGlass)

        substrate = c.value(.substrate, d.substrate)
        appearance = c.value(.appearance, d.appearance)
        translucency = c.value(.translucency, d.translucency)

        tint = c.value(.tint, d.tint)
        tintIntensity = c.value(.tintIntensity, d.tintIntensity)
        usesGradientTint = c.value(.usesGradientTint, d.usesGradientTint)
        secondaryTint = c.value(.secondaryTint, d.secondaryTint)
        midStops = Array((c.value(.midStops, [CodableColor]())).prefix(3))
        tintAngle = c.value(.tintAngle, d.tintAngle)
        textColorMode = c.value(.textColorMode, d.textColorMode)

        specularIntensity = c.value(.specularIntensity, d.specularIntensity)
        specularSpread = c.value(.specularSpread, d.specularSpread)
        rimIntensity = c.value(.rimIntensity, d.rimIntensity)
        rimWidth = c.value(.rimWidth, d.rimWidth)
        lensing = c.value(.lensing, d.lensing)
        grain = c.value(.grain, d.grain)
        depth = c.value(.depth, d.depth)

        rimColor = c.value(.rimColor, d.rimColor)
        glowColor = c.value(.glowColor, d.glowColor)
        glowIntensity = c.value(.glowIntensity, d.glowIntensity)
        tintCycleSeconds = c.value(.tintCycleSeconds, d.tintCycleSeconds)
        shadowColor = c.value(.shadowColor, d.shadowColor)
        iconSaturation = c.value(.iconSaturation, d.iconSaturation)
        tileShape = c.value(.tileShape, d.tileShape)
        tileBackingOpacity = c.value(.tileBackingOpacity, d.tileBackingOpacity)

        cornerRadius = c.value(.cornerRadius, d.cornerRadius)
        continuousCorners = c.value(.continuousCorners, d.continuousCorners)
        capsule = c.value(.capsule, d.capsule)
        padding = c.value(.padding, d.padding)

        shadowRadius = c.value(.shadowRadius, d.shadowRadius)
        shadowOpacity = c.value(.shadowOpacity, d.shadowOpacity)
        shadowYOffset = c.value(.shadowYOffset, d.shadowYOffset)
        sanitize()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(fillStyle, forKey: .fillStyle)
        try c.encode(nativeVariant, forKey: .nativeVariant)
        try c.encode(nativeInteractive, forKey: .nativeInteractive)
        try c.encode(followsSystemGlass, forKey: .followsSystemGlass)
        try c.encode(substrate, forKey: .substrate)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(translucency, forKey: .translucency)
        try c.encode(tint, forKey: .tint)
        try c.encode(tintIntensity, forKey: .tintIntensity)
        try c.encode(usesGradientTint, forKey: .usesGradientTint)
        try c.encode(secondaryTint, forKey: .secondaryTint)
        try c.encode(midStops, forKey: .midStops)
        try c.encode(tintAngle, forKey: .tintAngle)
        try c.encode(textColorMode, forKey: .textColorMode)
        try c.encode(specularIntensity, forKey: .specularIntensity)
        try c.encode(specularSpread, forKey: .specularSpread)
        try c.encode(rimIntensity, forKey: .rimIntensity)
        try c.encode(rimWidth, forKey: .rimWidth)
        try c.encode(lensing, forKey: .lensing)
        try c.encode(grain, forKey: .grain)
        try c.encode(depth, forKey: .depth)
        try c.encode(rimColor, forKey: .rimColor)
        try c.encode(glowColor, forKey: .glowColor)
        try c.encode(glowIntensity, forKey: .glowIntensity)
        try c.encode(tintCycleSeconds, forKey: .tintCycleSeconds)
        try c.encode(shadowColor, forKey: .shadowColor)
        try c.encode(iconSaturation, forKey: .iconSaturation)
        try c.encode(tileShape, forKey: .tileShape)
        try c.encode(tileBackingOpacity, forKey: .tileBackingOpacity)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(continuousCorners, forKey: .continuousCorners)
        try c.encode(capsule, forKey: .capsule)
        try c.encode(padding, forKey: .padding)
        try c.encode(shadowRadius, forKey: .shadowRadius)
        try c.encode(shadowOpacity, forKey: .shadowOpacity)
        try c.encode(shadowYOffset, forKey: .shadowYOffset)
        try c.encode(fillStyle == .native, forKey: .usesSystemGlass)
    }

    /// Clamps every numeric field into the range the renderer is built for.
    /// Themes arrive from disk and from imported profiles; a value of 1e9 for a
    /// shadow radius must not become a gigantic offscreen allocation.
    mutating func sanitize() {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            v.isFinite ? min(max(v, lo), hi) : lo
        }
        translucency = clamp(translucency, 0.05, 1)
        tintIntensity = clamp(tintIntensity, 0, 1)
        tintAngle = clamp(tintAngle, -360, 720)
        specularIntensity = clamp(specularIntensity, 0, 1)
        specularSpread = clamp(specularSpread, 0.1, 3)
        rimIntensity = clamp(rimIntensity, 0, 1)
        rimWidth = clamp(rimWidth, 0, 6)
        lensing = clamp(lensing, 0, 1)
        grain = clamp(grain, 0, 1)
        depth = clamp(depth, 0, 1)
        glowIntensity = clamp(glowIntensity, 0, 1)
        tintCycleSeconds = clamp(tintCycleSeconds, 0, 3600)
        iconSaturation = clamp(iconSaturation, 0, 3)
        tileBackingOpacity = clamp(tileBackingOpacity, 0, 1)
        cornerRadius = clamp(cornerRadius, 0, 80)
        padding = clamp(padding, 0, 40)
        shadowRadius = clamp(shadowRadius, 0, 80)
        shadowOpacity = clamp(shadowOpacity, 0, 1)
        shadowYOffset = clamp(shadowYOffset, -40, 60)
        if midStops.count > 3 { midStops = Array(midStops.prefix(3)) }
    }

    // MARK: Derived

    var shapeStyle: RoundedCornerStyle { continuousCorners ? .continuous : .circular }

    /// Legacy accessor for the 2.5 toggle.
    var usesSystemGlass: Bool {
        get { fillStyle == .native }
        set { fillStyle = newValue ? .native : (fillStyle == .native ? .glass : fillStyle) }
    }

    /// The palette as an ordered list of 1–5 colours.
    var tintStops: [CodableColor] {
        usesGradientTint ? [tint] + midStops + [secondaryTint] : [tint]
    }

    /// Replaces the palette. Accepts 1–5 stops.
    mutating func setStops(_ stops: [CodableColor], angle: Double? = nil) {
        guard let first = stops.first else { return }
        tint = first
        if stops.count == 1 {
            usesGradientTint = false
            midStops = []
        } else {
            usesGradientTint = true
            secondaryTint = stops[stops.count - 1]
            midStops = Array(stops.dropFirst().dropLast().prefix(3))
        }
        if let angle { tintAngle = angle }
    }

    /// The corner radius to draw a plate of `size` with. A capsule is as round
    /// as the short side allows; anything else is capped at that same limit so
    /// a huge radius on a small plate can't invert the shape.
    func resolvedCornerRadius(for size: CGSize) -> CGFloat {
        let limit = min(size.width, size.height) / 2
        return capsule ? limit : min(CGFloat(cornerRadius), limit)
    }

    /// Whether foreground content (labels, widget text) should be dark.
    ///
    /// Glass shows the desktop rather than the palette, so it follows the
    /// appearance. A gradient is judged by its own brightness, using Goorgle's
    /// rule: mostly the mean, pulled up by the brightest stop, so a yellow→red
    /// ramp that averages to a comfortable value doesn't hand white text to its
    /// yellow end.
    func prefersDarkForeground(systemIsDark: Bool) -> Bool {
        switch textColorMode {
        case .light: return false
        case .dark: return true
        case .auto:
            if fillStyle == .gradient {
                let values = tintStops.map(\.luminance)
                guard let brightest = values.max() else { return false }
                let mean = values.reduce(0, +) / Double(values.count)
                return mean * 0.7 + brightest * 0.3 > 0.66
            }
            switch appearance {
            case .light: return true
            case .dark: return false
            case .system: return !systemIsDark
            }
        }
    }

    /// A copy for editing: new identity, so saving it can't collide with or
    /// overwrite the preset it came from.
    func asEditableCopy() -> GlassTheme {
        var copy = self
        copy.id = UUID()
        return copy
    }

    /// Applies a palette without touching anything else about the design.
    func applying(_ palette: ColorPalette) -> GlassTheme {
        var copy = self
        copy.setStops(palette.colors, angle: palette.angle)
        return copy
    }
}
