import Foundation

/// A ready-made multicolour palette: 2–5 colours and the angle they run at.
///
/// The first nine are Goorgle's, so the same names mean the same colours in
/// both apps; the rest extend the set in the same spirit.
struct ColorPalette: Identifiable, Hashable {
    let id: String
    let name: String
    let hexes: [String]
    /// Degrees clockwise from straight down: 0 = ↓, 45 = ↘, 90 = →, 180 = ↑.
    let angle: Double

    var colors: [CodableColor] { hexes.map(CodableColor.init(hex:)) }

    static let all: [ColorPalette] = [
        // From Goorgle — the four Google colours, since that's the joke the
        // whole app is built on, and its eight siblings.
        ColorPalette(id: "goorgle", name: "Goorgle", hexes: ["4285F4", "EA4335", "FBBC05", "34A853"], angle: 45),
        ColorPalette(id: "sunset", name: "Sunset", hexes: ["FF6B6B", "FF8E53", "FFC371"], angle: 60),
        ColorPalette(id: "aurora", name: "Aurora", hexes: ["00C9A7", "4D9EF5", "845EC2"], angle: 45),
        ColorPalette(id: "candy", name: "Candy", hexes: ["FF5FA2", "FF8ADE", "C86DD7"], angle: 30),
        ColorPalette(id: "vapor", name: "Vaporwave", hexes: ["8E2DE2", "4A00E0", "00D2FF"], angle: 60),
        ColorPalette(id: "citrus", name: "Citrus", hexes: ["F9D423", "FF4E50"], angle: 90),
        ColorPalette(id: "mint", name: "Mint", hexes: ["43E97B", "38F9D7"], angle: 45),
        ColorPalette(id: "ocean", name: "Deep Ocean", hexes: ["0F2027", "203A43", "2C5364"], angle: 45),
        ColorPalette(id: "graphite", name: "Graphite", hexes: ["3A3A3C", "636366"], angle: 45),
        // New here.
        ColorPalette(id: "ember", name: "Ember", hexes: ["FF416C", "FF4B2B"], angle: 60),
        ColorPalette(id: "lagoon", name: "Lagoon", hexes: ["00C6FF", "0072FF"], angle: 45),
        ColorPalette(id: "orchid", name: "Orchid", hexes: ["DA22FF", "9733EE"], angle: 45),
        ColorPalette(id: "sakura", name: "Sakura", hexes: ["FBD3E9", "BB377D"], angle: 45),
        ColorPalette(id: "solar", name: "Solar", hexes: ["F7971E", "FFD200"], angle: 90),
        ColorPalette(id: "arctic", name: "Arctic", hexes: ["E0EAFC", "CFDEF3", "A9C4EB"], angle: 45),
        ColorPalette(id: "moss", name: "Moss", hexes: ["134E5E", "71B280"], angle: 45),
        ColorPalette(id: "twilight", name: "Twilight", hexes: ["0F0C29", "302B63", "24243E"], angle: 45),
        ColorPalette(id: "lime", name: "Lime Soda", hexes: ["B8FF3C", "00C9A7"], angle: 60),
        ColorPalette(id: "rose", name: "Rosé", hexes: ["F093FB", "F5576C"], angle: 45),
        ColorPalette(id: "mono", name: "Mono", hexes: ["F2F2F7", "8E8E93"], angle: 90),
    ]
}

extension GlassTheme {
    /// Builds a named design from a default theme plus tweaks.
    static func design(_ name: String, _ configure: (inout GlassTheme) -> Void) -> GlassTheme {
        var theme = GlassTheme()
        theme.name = name
        configure(&theme)
        theme.sanitize()
        return theme
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> CodableColor {
        CodableColor(red: r, green: g, blue: b, alpha: 1)
    }

    /// A Goorgle-style pill: a palette painted onto a fully rounded plate.
    private static func pill(_ name: String, _ paletteID: String, tweak: ((inout GlassTheme) -> Void)? = nil) -> GlassTheme {
        design(name) { t in
            let palette = ColorPalette.all.first { $0.id == paletteID } ?? ColorPalette.all[0]
            t.fillStyle = .gradient
            t.setStops(palette.colors, angle: palette.angle)
            t.tintIntensity = 0.94
            t.translucency = 1
            t.capsule = true
            t.specularIntensity = 0.28
            t.specularSpread = 0.8
            t.rimIntensity = 0.45
            t.rimWidth = 1
            t.lensing = 0.12
            t.grain = 0
            t.depth = 0.18
            t.padding = 11
            t.shadowRadius = 14
            t.shadowOpacity = 0.28
            t.shadowYOffset = 7
            tweak?(&t)
        }
    }

    /// Complete looks to start from. Each is copied into the user's editable
    /// theme rather than referenced, so tweaking never mutates a preset.
    static let presets: [GlassTheme] = [
        design("Liquid") { t in
            t.substrate = .hud; t.translucency = 0.92
            t.tint = rgb(0.42, 0.58, 0.96); t.tintIntensity = 0.18
            t.secondaryTint = rgb(0.86, 0.44, 0.94)
            t.specularIntensity = 0.55; t.specularSpread = 0.9
            t.rimIntensity = 0.6; t.rimWidth = 1; t.lensing = 0.5; t.grain = 0.12; t.depth = 0.35
            t.cornerRadius = 22; t.padding = 10
            t.shadowRadius = 18; t.shadowOpacity = 0.32; t.shadowYOffset = 6
        },
        design("Crystal") { t in
            t.substrate = .popover; t.translucency = 0.78
            t.tint = rgb(1, 1, 1); t.tintIntensity = 0.06; t.usesGradientTint = false
            t.specularIntensity = 0.85; t.specularSpread = 1.1
            t.rimIntensity = 0.9; t.rimWidth = 1.4; t.lensing = 0.7; t.grain = 0.03; t.depth = 0.2
            t.cornerRadius = 26; t.padding = 11
            t.shadowRadius = 24; t.shadowOpacity = 0.24; t.shadowYOffset = 8
        },
        design("Obsidian") { t in
            t.substrate = .underWindow; t.appearance = .dark; t.translucency = 0.96
            t.tint = rgb(0.05, 0.05, 0.08); t.tintIntensity = 0.55
            t.secondaryTint = rgb(0.16, 0.16, 0.22)
            t.specularIntensity = 0.35; t.specularSpread = 0.7
            t.rimIntensity = 0.4; t.rimWidth = 1; t.lensing = 0.35; t.grain = 0.18; t.depth = 0.5
            t.cornerRadius = 18; t.padding = 10
            t.shadowRadius = 26; t.shadowOpacity = 0.5; t.shadowYOffset = 8
        },
        design("Frost") { t in
            t.substrate = .sidebar; t.appearance = .light; t.translucency = 0.9
            t.tint = rgb(0.93, 0.96, 1); t.tintIntensity = 0.35; t.usesGradientTint = false
            t.specularIntensity = 0.4; t.specularSpread = 1
            t.rimIntensity = 0.5; t.rimWidth = 1.2; t.lensing = 0.3; t.grain = 0.28; t.depth = 0.22
            t.cornerRadius = 20; t.padding = 10
            t.shadowRadius = 14; t.shadowOpacity = 0.18; t.shadowYOffset = 4
        },
        design("Aurora") { t in
            t.substrate = .fullScreenUI; t.translucency = 0.88
            t.tint = rgb(0.16, 0.86, 0.72); t.tintIntensity = 0.28
            t.secondaryTint = rgb(0.36, 0.32, 0.95)
            t.specularIntensity = 0.7; t.specularSpread = 1.2
            t.rimIntensity = 0.65; t.rimWidth = 1.1; t.lensing = 0.55; t.grain = 0.08; t.depth = 0.4
            t.cornerRadius = 28; t.padding = 12
            t.shadowRadius = 22; t.shadowOpacity = 0.35; t.shadowYOffset = 7
        },
        design("Graphite") { t in
            t.substrate = .menu; t.translucency = 1
            t.tint = rgb(0.22, 0.22, 0.24); t.tintIntensity = 0.4; t.usesGradientTint = false
            t.specularIntensity = 0.15; t.specularSpread = 0.6
            t.rimIntensity = 0.3; t.rimWidth = 1; t.lensing = 0.2; t.grain = 0.05; t.depth = 0.25
            t.cornerRadius = 12; t.continuousCorners = false; t.padding = 8
            t.shadowRadius = 12; t.shadowOpacity = 0.4; t.shadowYOffset = 4
        },
        design("Neon") { t in
            t.substrate = .hud; t.appearance = .dark; t.translucency = 0.95
            t.tint = rgb(0.05, 0.02, 0.12); t.tintIntensity = 0.62
            t.secondaryTint = rgb(0.16, 0.02, 0.24)
            t.specularIntensity = 0.35; t.specularSpread = 0.8
            t.rimIntensity = 1; t.rimWidth = 2; t.lensing = 0.55; t.grain = 0.06; t.depth = 0.4
            t.rimColor = rgb(0.20, 1, 0.85); t.glowColor = rgb(0.95, 0.15, 0.75); t.glowIntensity = 0.75
            t.shadowColor = rgb(0.35, 0, 0.35); t.iconSaturation = 1.25
            t.tileShape = .circle; t.tileBackingOpacity = 0.14
            t.cornerRadius = 26; t.padding = 12
            t.shadowRadius = 28; t.shadowOpacity = 0.55; t.shadowYOffset = 6
        },
        design("Sunset Glass") { t in
            t.substrate = .fullScreenUI; t.translucency = 0.9
            t.tint = rgb(1, 0.45, 0.25); t.tintIntensity = 0.32
            t.secondaryTint = rgb(0.62, 0.18, 0.58)
            t.specularIntensity = 0.65; t.specularSpread = 1.15
            t.rimIntensity = 0.7; t.rimWidth = 1.2; t.lensing = 0.5; t.grain = 0.1; t.depth = 0.42
            t.rimColor = rgb(1, 0.86, 0.62); t.glowColor = rgb(1, 0.42, 0.20); t.glowIntensity = 0.4
            t.shadowColor = rgb(0.25, 0.06, 0.10); t.tileBackingOpacity = 0.10
            t.cornerRadius = 24; t.padding = 11
            t.shadowRadius = 22; t.shadowOpacity = 0.4; t.shadowYOffset = 7
        },
        design("Vapor") { t in
            t.substrate = .popover; t.translucency = 0.86
            t.tint = rgb(0.45, 0.85, 1); t.tintIntensity = 0.24
            t.secondaryTint = rgb(1, 0.52, 0.86)
            t.specularIntensity = 0.8; t.specularSpread = 1.3
            t.rimIntensity = 0.75; t.rimWidth = 1.4; t.lensing = 0.62; t.grain = 0.05; t.depth = 0.28
            t.rimColor = rgb(1, 0.95, 1); t.glowColor = rgb(0.55, 0.75, 1); t.glowIntensity = 0.5
            t.tintCycleSeconds = 90; t.shadowColor = rgb(0.20, 0.10, 0.35); t.iconSaturation = 1.1
            t.tileShape = .capsule; t.tileBackingOpacity = 0.12
            t.cornerRadius = 30; t.padding = 12
            t.shadowRadius = 26; t.shadowOpacity = 0.3; t.shadowYOffset = 8
        },
        design("Blueprint") { t in
            t.substrate = .underWindow; t.appearance = .dark; t.translucency = 1
            t.tint = rgb(0.03, 0.12, 0.32); t.tintIntensity = 0.72; t.usesGradientTint = false
            t.specularIntensity = 0.2; t.specularSpread = 0.7
            t.rimIntensity = 0.85; t.rimWidth = 1; t.lensing = 0.2; t.grain = 0.22; t.depth = 0.3
            t.rimColor = rgb(0.55, 0.85, 1); t.glowColor = rgb(0.2, 0.6, 1); t.glowIntensity = 0.25
            t.shadowColor = rgb(0, 0.05, 0.2); t.iconSaturation = 0.35
            t.tileShape = .rounded; t.tileBackingOpacity = 0.10
            t.cornerRadius = 8; t.continuousCorners = false; t.padding = 10
            t.shadowRadius = 16; t.shadowOpacity = 0.45; t.shadowYOffset = 4
        },

        // Apple's own Liquid Glass.
        design("Clear Glass") { t in
            t.fillStyle = .native; t.nativeVariant = .clear
            t.cornerRadius = 26; t.padding = 10
            t.shadowRadius = 20; t.shadowOpacity = 0.22; t.shadowYOffset = 6
        },
        design("Frosted Glass") { t in
            t.fillStyle = .native; t.nativeVariant = .regular
            t.cornerRadius = 26; t.padding = 10
            t.shadowRadius = 20; t.shadowOpacity = 0.22; t.shadowYOffset = 6
        },
        design("Tahoe") { t in
            t.fillStyle = .native; t.nativeVariant = .regular
            t.tint = rgb(0.29, 0.52, 1); t.tintIntensity = 0.55; t.usesGradientTint = false
            t.cornerRadius = 24; t.padding = 11
            t.shadowRadius = 22; t.shadowOpacity = 0.26; t.shadowYOffset = 7
        },

        // Goorgle's pills.
        pill("Goorgle", "goorgle"),
        pill("Sunset Pill", "sunset"),
        pill("Aurora Pill", "aurora"),
        pill("Candy", "candy"),
        pill("Vaporwave", "vapor"),
        pill("Citrus", "citrus"),
        pill("Mint", "mint"),
        pill("Deep Ocean", "ocean"),
        pill("Graphite Pill", "graphite"),

        // More character.
        design("Midnight") { t in
            t.substrate = .hud; t.appearance = .dark; t.translucency = 0.94
            t.tint = rgb(0.10, 0.11, 0.30); t.tintIntensity = 0.5
            t.secondaryTint = rgb(0.25, 0.12, 0.40)
            t.specularIntensity = 0.45; t.specularSpread = 0.9
            t.rimIntensity = 0.6; t.lensing = 0.45; t.grain = 0.14; t.depth = 0.42
            t.rimColor = rgb(0.70, 0.75, 1); t.glowColor = rgb(0.40, 0.45, 1); t.glowIntensity = 0.3
            t.shadowColor = rgb(0.05, 0.03, 0.20)
            t.cornerRadius = 24; t.padding = 11
            t.shadowRadius = 26; t.shadowOpacity = 0.5; t.shadowYOffset = 8
        },
        design("Rosewater") { t in
            t.substrate = .popover; t.appearance = .light; t.translucency = 0.88
            t.tint = rgb(1, 0.82, 0.88); t.tintIntensity = 0.42
            t.secondaryTint = rgb(0.96, 0.70, 0.85)
            t.specularIntensity = 0.6; t.specularSpread = 1.1
            t.rimIntensity = 0.7; t.rimWidth = 1.2; t.lensing = 0.5; t.grain = 0.1; t.depth = 0.28
            t.shadowColor = rgb(0.5, 0.2, 0.3)
            t.cornerRadius = 26; t.padding = 11
            t.shadowRadius = 20; t.shadowOpacity = 0.22; t.shadowYOffset = 6
        },
        design("Terminal") { t in
            t.fillStyle = .gradient
            t.setStops([CodableColor(hex: "0B0F0B"), CodableColor(hex: "142014")], angle: 90)
            t.tintIntensity = 0.96; t.translucency = 0.97
            t.rimColor = rgb(0.20, 1, 0.30); t.rimIntensity = 0.9; t.rimWidth = 1.2
            t.glowColor = rgb(0.20, 1, 0.30); t.glowIntensity = 0.4
            t.specularIntensity = 0.1; t.lensing = 0.15; t.grain = 0; t.depth = 0.1
            t.iconSaturation = 0.6; t.tileShape = .rounded; t.tileBackingOpacity = 0.12
            t.textColorMode = .light
            t.cornerRadius = 8; t.continuousCorners = false; t.padding = 9
            t.shadowRadius = 18; t.shadowOpacity = 0.5; t.shadowYOffset = 4
        },
        design("Paper") { t in
            t.fillStyle = .gradient
            t.setStops([CodableColor(hex: "FFFFFF"), CodableColor(hex: "F0F0F5")], angle: 0)
            t.tintIntensity = 0.96; t.translucency = 1
            t.rimColor = rgb(0, 0, 0); t.rimIntensity = 0.22; t.rimWidth = 1
            t.specularIntensity = 0.15; t.lensing = 0; t.grain = 0.05; t.depth = 0.1
            t.cornerRadius = 16; t.padding = 10
            t.shadowRadius = 14; t.shadowOpacity = 0.18; t.shadowYOffset = 3
        },
    ]

    static var allPresets: [GlassTheme] { presets }
}
