import Foundation
import CoreGraphics
import AppKit
import SwiftUI

enum DockEdge: String, Codable, CaseIterable, Identifiable {
    case bottom, top, left, right
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottom: return "Bottom"
        case .top: return "Top"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
    var isHorizontal: Bool { self == .bottom || self == .top }
}

/// Which tiles a dock shows, beyond the ones the user placed by hand.
enum DockContentMode: String, Codable, CaseIterable, Identifiable {
    /// Only what the user added.
    case manual
    /// The user's tiles, filtered down to apps that are currently running.
    case runningOnly
    /// The user's tiles, filtered to apps with a window on the Space in view.
    case currentSpace
    /// A live mirror of the real Dock — the user's own tiles are ignored.
    case liveDock

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "My Items"
        case .runningOnly: return "Running Apps Only"
        case .currentSpace: return "Apps in This Space"
        case .liveDock: return "Mirror the System Dock"
        }
    }

    var explanation: String {
        switch self {
        case .manual:
            return "Shows exactly the tiles you add below."
        case .runningOnly:
            return "Hides your tiles whose app isn't running right now."
        case .currentSpace:
            return "Hides your tiles whose app has no window on the Space you're looking at."
        case .liveDock:
            return "Mirrors whatever is in your real Dock — handy on a second display. Your own tiles below are ignored in this mode."
        }
    }

    /// Whether this mode needs the running-apps/Space watcher running.
    var needsRunningApps: Bool { self == .runningOnly || self == .currentSpace }
}

/// How a dock collapses when idle. XtraDock's "shrink any dock into a single
/// button and expand it with a hover or a click".
enum DockCollapseMode: String, Codable, CaseIterable, Identifiable {
    case never
    /// Collapses to a small pill; hovering it expands the dock.
    case toButtonOnHover
    /// Collapses to a small pill; it takes a click to expand.
    case toButtonOnClick
    /// Fades out entirely until the pointer reaches the screen edge.
    case fadeOut

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: return "Always Visible"
        case .toButtonOnHover: return "Collapse to a Button (expand on hover)"
        case .toButtonOnClick: return "Collapse to a Button (expand on click)"
        case .fadeOut: return "Hide Completely (show on edge hover)"
        }
    }

    var collapsesToButton: Bool { self == .toButtonOnHover || self == .toButtonOnClick }
    var isEnabled: Bool { self != .never }
}

/// A display reference that survives being unplugged.
///
/// `CGDirectDisplayID` is reassigned across reconnects, so a dock pinned only
/// by that number lands on the wrong screen — or the main one — after a monitor
/// comes back. The UUID is stable for the life of the physical display, so it's
/// the primary key here; the numeric ID and the name are kept as fallbacks for
/// displays that report no UUID at all.
struct DisplayIdentity: Codable, Equatable, Hashable {
    var uuid: String?
    var displayID: Int
    var name: String

    init(uuid: String? = nil, displayID: Int = Int(CGMainDisplayID()), name: String = "Main Display") {
        self.uuid = uuid
        self.displayID = displayID
        self.name = name
    }

    init(screen: NSScreen) {
        displayID = screen.displayID ?? Int(CGMainDisplayID())
        name = screen.localizedName
        uuid = screen.displayUUID
    }

    static var main: DisplayIdentity {
        NSScreen.main.map(DisplayIdentity.init(screen:)) ?? DisplayIdentity()
    }

    /// Resolution order: exact UUID, then numeric ID, then name, then the main
    /// display. Each step is a weaker claim than the one before, but any of
    /// them beats dropping the panel on the floor.
    func resolve() -> NSScreen? {
        if let uuid, let match = NSScreen.screens.first(where: { $0.displayUUID == uuid }) {
            return match
        }
        if let match = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            return match
        }
        if let match = NSScreen.screens.first(where: { $0.localizedName == name }) {
            return match
        }
        return NSScreen.main
    }

    var isConnected: Bool {
        if let uuid { return NSScreen.screens.contains { $0.displayUUID == uuid } }
        return NSScreen.screens.contains { $0.displayID == displayID }
    }
}

/// How a running app is marked on its tile.
enum IndicatorStyle: String, Codable, CaseIterable, Identifiable {
    case dot, bar, ring, glow, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dot: return "Dot"
        case .bar: return "Bar"
        case .ring: return "Ring"
        case .glow: return "Glow"
        case .none: return "None"
        }
    }

    /// Whether the marker needs room reserved beneath the icon. Ring and glow
    /// are drawn over the tile, so they don't change the dock's height.
    var needsGutter: Bool { self == .dot || self == .bar }
}

/// What a tile does as the pointer passes over it.
enum HoverStyle: String, Codable, CaseIterable, Identifiable {
    case magnify, lift, tilt, glow, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .magnify: return "Magnify"
        case .lift: return "Lift"
        case .tilt: return "Tilt"
        case .glow: return "Glow"
        case .none: return "Nothing"
        }
    }
}

/// Whether a dock floats as a pill or stretches the whole edge like a taskbar.
enum DockLayoutMode: String, Codable, CaseIterable, Identifiable {
    case floating, stretch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .floating: return "Floating Pill"
        case .stretch: return "Edge to Edge"
        }
    }
}

/// How close the pointer has to get to a hidden dock's edge to bring it back.
enum RevealZone: String, Codable, CaseIterable, Identifiable {
    case narrow, standard, wide
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Depth of the strip at the screen edge that counts as "reaching for it".
    var depth: CGFloat {
        switch self {
        case .narrow: return 2
        case .standard: return 5
        case .wide: return 14
        }
    }
}

/// How a dock arrives and leaves.
enum AppearAnimation: String, Codable, CaseIterable, Identifiable {
    case fade, slide, pop, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fade: return "Fade"
        case .slide: return "Slide"
        case .pop: return "Pop"
        case .none: return "None"
        }
    }
}

/// Whether the dock floats above windows or sits behind them like a widget.
enum DockLevel: String, Codable, CaseIterable, Identifiable {
    case floating, desktop
    var id: String { rawValue }
    var label: String { self == .floating ? "Above Windows" : "Behind Windows (Desktop)" }
}

enum SpacingPreset: String, Codable, CaseIterable, Identifiable {
    case compact, standard, roomy, spacious
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var gap: CGFloat {
        switch self {
        case .compact: return 3
        case .standard: return 8
        case .roomy: return 13
        case .spacious: return 20
        }
    }
}

/// A global keyboard shortcut, stored as a Carbon key code and modifier mask
/// (the form `RegisterEventHotKey` takes).
struct HotKeySpec: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
}

struct SecondaryDock: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "New Dock"
    var isEnabled: Bool = true

    // Placement
    var edge: DockEdge = .bottom
    var display: DisplayIdentity = .main
    /// Position along the edge, 0 = leading, 0.5 = centred, 1 = trailing.
    var alignment: Double = 0.5
    var edgeMargin: Double = 8
    /// Mirrors this dock onto every connected display, managed as one dock.
    var showsOnAllScreens: Bool = false
    var windowLevel: DockLevel = .floating

    // Tiles
    var contentMode: DockContentMode = .manual
    var items: [DockItem] = []
    var tileSize: Double = 48
    var magnificationEnabled: Bool = true
    var magnifiedTileSize: Double = 68
    var spacing: SpacingPreset = .standard
    var showsRunningIndicators: Bool = true
    var indicatorStyle: IndicatorStyle = .dot
    var indicatorColor: CodableColor = CodableColor(red: 1, green: 1, blue: 1, alpha: 1)
    var hoverStyle: HoverStyle = .magnify
    var layoutMode: DockLayoutMode = .floating
    /// Renders apps that aren't running in greyscale, so the dock reads at a
    /// glance without hiding anything.
    var dimsNonRunningApps: Bool = false
    var showsLabels: Bool = false
    /// ExtraBar's Inline mode: also place this dock's app and action tiles in
    /// the menu bar as individual status items.
    var showsInlineMenuBarItems: Bool = false
    /// Bundle identifiers hidden from a mirrored dock.
    var hiddenBundleIDs: [String] = []
    /// A locked dock can only be rearranged or added to in Edit mode, so a
    /// stray drag can't pull a tile out or a stray drop pin something.
    var isLocked: Bool = false

    // Behaviour
    var collapseMode: DockCollapseMode = .never
    /// Seconds of no pointer contact before a collapsing dock collapses.
    var collapseDelay: Double = 0.8
    var revealZone: RevealZone = .standard
    var appearAnimation: AppearAnimation = .fade
    /// Steps aside while a full-screen app is in front.
    var hidesInFullscreen: Bool = false
    /// Fades when another app's window overlaps it, letting clicks through.
    var hidesOnWindowOverlap: Bool = false
    /// While hidden by one of the above, brings the dock back when the pointer
    /// rests at its screen edge.
    var revealsAtEdgeWhenHidden: Bool = true
    var hotkey: HotKeySpec?
    /// Text for the collapsed button, up to three characters. Empty = a chevron.
    var collapseGlyph: String = ""

    // Appearance
    /// `nil` means "follow the app's active theme". A UUID pins this dock to a
    /// specific saved theme, so one dock can be Obsidian while another is Frost.
    var themeOverrideID: UUID?

    init(
        id: UUID = UUID(),
        name: String = "New Dock",
        isEnabled: Bool = true,
        edge: DockEdge = .bottom,
        display: DisplayIdentity = .main,
        alignment: Double = 0.5,
        edgeMargin: Double = 8,
        contentMode: DockContentMode = .manual,
        items: [DockItem] = [],
        tileSize: Double = 48,
        magnificationEnabled: Bool = true,
        magnifiedTileSize: Double = 68,
        showsRunningIndicators: Bool = true,
        layoutMode: DockLayoutMode = .floating
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.edge = edge
        self.display = display
        self.alignment = alignment
        self.edgeMargin = edgeMargin
        self.contentMode = contentMode
        self.items = items
        self.tileSize = tileSize
        self.magnificationEnabled = magnificationEnabled
        self.magnifiedTileSize = magnifiedTileSize
        self.showsRunningIndicators = showsRunningIndicators
        self.layoutMode = layoutMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, edge, display, alignment, edgeMargin, showsOnAllScreens, windowLevel,
             contentMode, items, tileSize, magnificationEnabled, magnifiedTileSize, spacing,
             showsRunningIndicators, indicatorStyle, indicatorColor, hoverStyle, layoutMode,
             dimsNonRunningApps, showsLabels, showsInlineMenuBarItems, hiddenBundleIDs, isLocked,
             collapseMode, collapseDelay, revealZone, appearAnimation, hidesInFullscreen,
             hidesOnWindowOverlap, revealsAtEdgeWhenHidden, hotkey, collapseGlyph, themeOverrideID
        // Retired keys, still read so docks saved by 1.x survive the upgrade.
        case displayID, autohideEnabled
    }

    /// Hand-written so fields added after a dock was first saved fall back to
    /// their default instead of failing the whole decode — and so a single
    /// unreadable field costs that field, not the dock. It also carries 1.x
    /// docks forward: the old flat `displayID` becomes a `DisplayIdentity`, and
    /// the old `autohideEnabled` boolean becomes the equivalent `collapseMode`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SecondaryDock()
        id = c.value(.id, UUID())
        name = String(c.value(.name, d.name).prefix(120))
        isEnabled = c.value(.isEnabled, true)
        edge = c.value(.edge, DockEdge.bottom)

        if let display = try? c.decodeIfPresent(DisplayIdentity.self, forKey: .display) {
            self.display = display
        } else if let legacyID = try? c.decodeIfPresent(Int.self, forKey: .displayID) {
            // A 1.x dock only knew a numeric ID. If that display is attached
            // right now, upgrade it to a full identity (UUID included) so the
            // pin becomes reconnect-proof from here on.
            if let screen = NSScreen.screens.first(where: { $0.displayID == legacyID }) {
                self.display = DisplayIdentity(screen: screen)
            } else {
                self.display = DisplayIdentity(uuid: nil, displayID: legacyID, name: "Display \(legacyID)")
            }
        } else {
            self.display = .main
        }

        alignment = c.value(.alignment, d.alignment)
        edgeMargin = c.value(.edgeMargin, d.edgeMargin)
        showsOnAllScreens = c.value(.showsOnAllScreens, false)
        windowLevel = c.value(.windowLevel, DockLevel.floating)
        contentMode = c.value(.contentMode, DockContentMode.manual)
        items = Array(c.value(.items, [DockItem]()).prefix(300))
        tileSize = c.value(.tileSize, d.tileSize)
        magnificationEnabled = c.value(.magnificationEnabled, true)
        magnifiedTileSize = c.value(.magnifiedTileSize, d.magnifiedTileSize)
        spacing = c.value(.spacing, SpacingPreset.standard)
        showsRunningIndicators = c.value(.showsRunningIndicators, true)
        indicatorStyle = c.value(.indicatorStyle, IndicatorStyle.dot)
        indicatorColor = c.value(.indicatorColor, d.indicatorColor)
        hoverStyle = c.value(.hoverStyle, HoverStyle.magnify)
        layoutMode = c.value(.layoutMode, DockLayoutMode.floating)
        dimsNonRunningApps = c.value(.dimsNonRunningApps, false)
        showsLabels = c.value(.showsLabels, false)
        showsInlineMenuBarItems = c.value(.showsInlineMenuBarItems, false)
        hiddenBundleIDs = Array(c.value(.hiddenBundleIDs, [String]()).prefix(200))
        // Docks saved before locking existed keep behaving as they did.
        isLocked = c.value(.isLocked, false)

        if let mode = try? c.decodeIfPresent(DockCollapseMode.self, forKey: .collapseMode) {
            collapseMode = mode
        } else if (try? c.decodeIfPresent(Bool.self, forKey: .autohideEnabled)) == true {
            collapseMode = .fadeOut
        } else {
            collapseMode = .never
        }
        collapseDelay = c.value(.collapseDelay, d.collapseDelay)
        revealZone = c.value(.revealZone, RevealZone.standard)
        appearAnimation = c.value(.appearAnimation, AppearAnimation.fade)
        hidesInFullscreen = c.value(.hidesInFullscreen, false)
        hidesOnWindowOverlap = c.value(.hidesOnWindowOverlap, false)
        revealsAtEdgeWhenHidden = c.value(.revealsAtEdgeWhenHidden, true)
        hotkey = try? c.decodeIfPresent(HotKeySpec.self, forKey: .hotkey)
        collapseGlyph = String(c.value(.collapseGlyph, "").prefix(3))
        themeOverrideID = try? c.decodeIfPresent(UUID.self, forKey: .themeOverrideID)
        sanitize()
    }

    /// Keeps every number inside the range the renderer is built for. Docks
    /// arrive from disk and from imported profiles, and an absurd tile size
    /// must not turn into an absurd bitmap allocation.
    mutating func sanitize() {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isFinite ? min(max(v, lo), hi) : lo }
        tileSize = clamp(tileSize, 16, 160)
        magnifiedTileSize = clamp(magnifiedTileSize, tileSize, 480)
        alignment = clamp(alignment, 0, 1)
        edgeMargin = clamp(edgeMargin, 0, 300)
        collapseDelay = clamp(collapseDelay, 0, 60)
    }

    /// The space between tiles, in points.
    var gap: CGFloat { spacing.gap }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(edge, forKey: .edge)
        try c.encode(display, forKey: .display)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(edgeMargin, forKey: .edgeMargin)
        try c.encode(showsOnAllScreens, forKey: .showsOnAllScreens)
        try c.encode(windowLevel, forKey: .windowLevel)
        try c.encode(contentMode, forKey: .contentMode)
        try c.encode(items, forKey: .items)
        try c.encode(tileSize, forKey: .tileSize)
        try c.encode(magnificationEnabled, forKey: .magnificationEnabled)
        try c.encode(magnifiedTileSize, forKey: .magnifiedTileSize)
        try c.encode(spacing, forKey: .spacing)
        try c.encode(showsRunningIndicators, forKey: .showsRunningIndicators)
        try c.encode(indicatorStyle, forKey: .indicatorStyle)
        try c.encode(indicatorColor, forKey: .indicatorColor)
        try c.encode(hoverStyle, forKey: .hoverStyle)
        try c.encode(layoutMode, forKey: .layoutMode)
        try c.encode(dimsNonRunningApps, forKey: .dimsNonRunningApps)
        try c.encode(showsLabels, forKey: .showsLabels)
        try c.encode(showsInlineMenuBarItems, forKey: .showsInlineMenuBarItems)
        try c.encode(hiddenBundleIDs, forKey: .hiddenBundleIDs)
        try c.encode(isLocked, forKey: .isLocked)
        try c.encode(collapseMode, forKey: .collapseMode)
        try c.encode(collapseDelay, forKey: .collapseDelay)
        try c.encode(revealZone, forKey: .revealZone)
        try c.encode(appearAnimation, forKey: .appearAnimation)
        try c.encode(hidesInFullscreen, forKey: .hidesInFullscreen)
        try c.encode(hidesOnWindowOverlap, forKey: .hidesOnWindowOverlap)
        try c.encode(revealsAtEdgeWhenHidden, forKey: .revealsAtEdgeWhenHidden)
        try c.encodeIfPresent(hotkey, forKey: .hotkey)
        try c.encode(collapseGlyph, forKey: .collapseGlyph)
        try c.encodeIfPresent(themeOverrideID, forKey: .themeOverrideID)
    }

    /// The tiles actually rendered right now, after the content mode filter.
    /// `liveDock` substitutes the mirrored system Dock wholesale; the two
    /// filtering modes keep non-app tiles (widgets, actions, spacers)
    /// unconditionally, since "is it running" is meaningless for them.
    func visibleItems(
        liveDockItems: [DockItem],
        runningBundleIDs: Set<String>,
        spaceBundleIDs: Set<String>,
        isSpaceDataUsable: Bool = true
    ) -> [DockItem] {
        switch contentMode {
        case .manual:
            return items
        case .liveDock:
            guard !hiddenBundleIDs.isEmpty else { return liveDockItems }
            let hidden = Set(hiddenBundleIDs)
            return liveDockItems.filter { item in item.bundleIdentifier.map { !hidden.contains($0) } ?? true }
        case .runningOnly, .currentSpace:
            // Space filtering degrades to running-apps filtering rather than
            // to an empty dock when the window list can't be read.
            let useSpace = contentMode == .currentSpace && isSpaceDataUsable
            let allowed = useSpace ? spaceBundleIDs : runningBundleIDs
            return items.filter { item in
                guard item.kind == .file else { return true }
                guard let bundleID = item.bundleIdentifier else { return true }
                return allowed.contains(bundleID)
            }
        }
    }
}

extension NSScreen {
    var displayID: Int? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }

    /// The display's hardware UUID, stable across unplug/replug. Some virtual
    /// and mirrored displays report none, hence the optional.
    var displayUUID: String? {
        guard let displayID else { return nil }
        guard let reference = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(displayID)) else { return nil }
        let uuid = reference.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
