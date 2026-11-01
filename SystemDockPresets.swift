import Foundation

/// Named bundles of the real Dock's own tunable settings.
///
/// "Theme" undersells what these actually are, and it's worth being upfront
/// about why: `com.apple.dock` has no colour, tint, or material key at all —
/// the real Dock is rendered by a private, unthemeable system material, which
/// is exactly why Dawck's own floating docks exist as a separate thing with a
/// full glass engine. What *is* real and available here is the Dock's
/// behaviour — size, position, motion, density — and a preset bundles a
/// coherent combination of that in one click, the same way a design theme
/// bundles typography and spacing rather than just a colour.
struct SystemDockPreset: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let blurb: String
    let apply: (inout DockDefaultsManager.Settings) -> Void

    static let all: [SystemDockPreset] = [
        SystemDockPreset(
            id: "compact",
            name: "Compact",
            symbol: "arrow.down.right.and.arrow.up.left",
            blurb: "Small icons, no magnification, tucked away until summoned.",
            apply: { s in
                s.tileSize = 38
                s.magnificationEnabled = false
                s.position = .bottom
                s.autohide = true
                s.autohideDelay = 0.3
                s.autohideAnimationDuration = 0.35
                s.showRecentApplications = false
                s.minimizeEffect = .scale
            }
        ),
        SystemDockPreset(
            id: "spacious",
            name: "Spacious",
            symbol: "arrow.up.left.and.arrow.down.right",
            blurb: "Large icons with a generous magnification wave, always visible.",
            apply: { s in
                s.tileSize = 68
                s.magnificationEnabled = true
                s.magnifiedTileSize = 100
                s.position = .bottom
                s.autohide = false
                s.showRecentApplications = true
                s.minimizeEffect = .genie
            }
        ),
        SystemDockPreset(
            id: "classic",
            name: "Classic",
            symbol: "clock.arrow.circlepath",
            blurb: "The long-standing macOS default: moderate size, gentle magnification.",
            apply: { s in
                s.tileSize = 48
                s.magnificationEnabled = true
                s.magnifiedTileSize = 64
                s.position = .bottom
                s.autohide = false
                s.showRecentApplications = true
                s.minimizeEffect = .genie
                s.launchAnimation = true
            }
        ),
        SystemDockPreset(
            id: "minimal",
            name: "Minimal",
            symbol: "minus.circle",
            blurb: "Only the apps you're running, no recents, no bounce, no ceremony.",
            apply: { s in
                s.tileSize = 42
                s.magnificationEnabled = false
                s.showRecentApplications = false
                s.showOnlyOpenApplications = true
                s.bouncesOnNotification = false
                s.launchAnimation = false
                s.showProcessIndicators = false
            }
        ),
        SystemDockPreset(
            id: "sidebar",
            name: "Side Rail",
            symbol: "sidebar.left",
            blurb: "Moved to the left edge, small and out of the way of a widescreen layout.",
            apply: { s in
                s.position = .left
                s.tileSize = 44
                s.magnificationEnabled = true
                s.magnifiedTileSize = 60
                s.autohide = false
            }
        ),
        SystemDockPreset(
            id: "poweruser",
            name: "Power User",
            symbol: "bolt.fill",
            blurb: "Auto-hides fast, groups windows by app, and switches Spaces by recency.",
            apply: { s in
                s.autohide = true
                s.autohideDelay = 0.1
                s.autohideAnimationDuration = 0.2
                s.groupsWindowsByApp = true
                s.rearrangesSpacesByUse = true
                s.scrollToOpen = true
                s.minimizeToApplication = true
            }
        )
    ]

    func settings(from base: DockDefaultsManager.Settings) -> DockDefaultsManager.Settings {
        var copy = base
        apply(&copy)
        return copy
    }
}
