import Foundation

/// A named snapshot of an entire Dawck setup: the system Dock's settings, every
/// custom dock, and the glass theme. Switching profiles swaps all three at once
/// — the point is to move between whole workspace layouts ("Desk", "Laptop",
/// "Presenting") in one click, not to tweak one setting at a time.
struct DockProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// Applying a profile restarts the Dock, which is briefly disruptive. A
    /// profile that only changes custom docks can skip that entirely.
    var includesSystemDock: Bool = true
    var systemDock: SystemDockSettings
    var docks: [SecondaryDock]
    var theme: GlassTheme

    /// A plain-data mirror of `DockDefaultsManager.Settings` so a profile can
    /// be encoded. The manager's own struct stays free of `Codable` and of any
    /// obligation to keep its stored shape stable.
    struct SystemDockSettings: Codable, Equatable {
        var tileSize: Double = 48
        var magnificationEnabled: Bool = false
        var magnifiedTileSize: Double = 64
        var position: String = "bottom"
        var minimizeEffect: String = "genie"
        var minimizeToApplication: Bool = false
        var autohide: Bool = false
        var autohideDelay: Double = 0.5
        var autohideAnimationDuration: Double = 0.5
        var showRecentApplications: Bool = true
        var showOnlyOpenApplications: Bool = false
        var singleAppMode: Bool = false
        var launchAnimation: Bool = true
        var showProcessIndicators: Bool = true
        var pinning: String = "middle"
        var bouncesOnNotification: Bool = true
        var dimsHiddenApps: Bool = false
        var groupsWindowsByApp: Bool = false
        var rearrangesSpacesByUse: Bool = true
        var scrollToOpen: Bool = false
        var springLoadsAllItems: Bool = false
        var appSwitcherOnAllDisplays: Bool = false
        var sizeLocked: Bool = false
        var positionLocked: Bool = false
        var contentsLocked: Bool = false
        var recentAppsCount: Int = 3
        var highlightsStacksOnHover: Bool = false

        init() {}

        /// Clamps values that will be written into the real Dock's preferences.
        mutating func sanitize() {
            func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isFinite ? min(max(v, lo), hi) : lo }
            tileSize = clamp(tileSize, 16, 128)
            magnifiedTileSize = clamp(magnifiedTileSize, 16, 128)
            autohideDelay = clamp(autohideDelay, 0, 5)
            autohideAnimationDuration = clamp(autohideAnimationDuration, 0, 3)
            recentAppsCount = min(max(recentAppsCount, 1), 12)
            if DockPosition(rawValue: position) == nil { position = "bottom" }
            if DockMinimizeEffect(rawValue: minimizeEffect) == nil { minimizeEffect = "genie" }
            if DockPinning(rawValue: pinning) == nil { pinning = "middle" }
        }

        init(_ settings: DockDefaultsManager.Settings) {
            tileSize = settings.tileSize
            magnificationEnabled = settings.magnificationEnabled
            magnifiedTileSize = settings.magnifiedTileSize
            position = settings.position.rawValue
            minimizeEffect = settings.minimizeEffect.rawValue
            minimizeToApplication = settings.minimizeToApplication
            autohide = settings.autohide
            autohideDelay = settings.autohideDelay
            autohideAnimationDuration = settings.autohideAnimationDuration
            showRecentApplications = settings.showRecentApplications
            showOnlyOpenApplications = settings.showOnlyOpenApplications
            singleAppMode = settings.singleAppMode
            launchAnimation = settings.launchAnimation
            showProcessIndicators = settings.showProcessIndicators
            pinning = settings.pinning.rawValue
            bouncesOnNotification = settings.bouncesOnNotification
            dimsHiddenApps = settings.dimsHiddenApps
            groupsWindowsByApp = settings.groupsWindowsByApp
            rearrangesSpacesByUse = settings.rearrangesSpacesByUse
            scrollToOpen = settings.scrollToOpen
            springLoadsAllItems = settings.springLoadsAllItems
            appSwitcherOnAllDisplays = settings.appSwitcherOnAllDisplays
            sizeLocked = settings.sizeLocked
            positionLocked = settings.positionLocked
            contentsLocked = settings.contentsLocked
            recentAppsCount = settings.recentAppsCount
            highlightsStacksOnHover = settings.highlightsStacksOnHover
        }

        var settings: DockDefaultsManager.Settings {
            DockDefaultsManager.Settings(
                tileSize: tileSize,
                magnificationEnabled: magnificationEnabled,
                magnifiedTileSize: magnifiedTileSize,
                position: DockPosition(rawValue: position) ?? .bottom,
                minimizeEffect: DockMinimizeEffect(rawValue: minimizeEffect) ?? .genie,
                minimizeToApplication: minimizeToApplication,
                autohide: autohide,
                autohideDelay: autohideDelay,
                autohideAnimationDuration: autohideAnimationDuration,
                showRecentApplications: showRecentApplications,
                showOnlyOpenApplications: showOnlyOpenApplications,
                singleAppMode: singleAppMode,
                launchAnimation: launchAnimation,
                showProcessIndicators: showProcessIndicators,
                pinning: DockPinning(rawValue: pinning) ?? .middle,
                bouncesOnNotification: bouncesOnNotification,
                dimsHiddenApps: dimsHiddenApps,
                groupsWindowsByApp: groupsWindowsByApp,
                rearrangesSpacesByUse: rearrangesSpacesByUse,
                scrollToOpen: scrollToOpen,
                springLoadsAllItems: springLoadsAllItems,
                appSwitcherOnAllDisplays: appSwitcherOnAllDisplays,
                sizeLocked: sizeLocked,
                positionLocked: positionLocked,
                contentsLocked: contentsLocked,
                recentAppsCount: recentAppsCount,
                highlightsStacksOnHover: highlightsStacksOnHover
            )
        }

        private enum CodingKeys: String, CodingKey {
            case tileSize, magnificationEnabled, magnifiedTileSize, position,
                 minimizeEffect, minimizeToApplication, autohide, autohideDelay,
                 autohideAnimationDuration, showRecentApplications,
                 showOnlyOpenApplications, singleAppMode, launchAnimation,
                 showProcessIndicators, pinning, bouncesOnNotification,
                 dimsHiddenApps, groupsWindowsByApp, rearrangesSpacesByUse,
                 scrollToOpen, springLoadsAllItems, appSwitcherOnAllDisplays,
                 sizeLocked, positionLocked, contentsLocked, recentAppsCount,
                 highlightsStacksOnHover
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = SystemDockSettings()
            tileSize = try c.decodeIfPresent(Double.self, forKey: .tileSize) ?? d.tileSize
            magnificationEnabled = try c.decodeIfPresent(Bool.self, forKey: .magnificationEnabled) ?? d.magnificationEnabled
            magnifiedTileSize = try c.decodeIfPresent(Double.self, forKey: .magnifiedTileSize) ?? d.magnifiedTileSize
            position = try c.decodeIfPresent(String.self, forKey: .position) ?? d.position
            minimizeEffect = try c.decodeIfPresent(String.self, forKey: .minimizeEffect) ?? d.minimizeEffect
            minimizeToApplication = try c.decodeIfPresent(Bool.self, forKey: .minimizeToApplication) ?? d.minimizeToApplication
            autohide = try c.decodeIfPresent(Bool.self, forKey: .autohide) ?? d.autohide
            autohideDelay = try c.decodeIfPresent(Double.self, forKey: .autohideDelay) ?? d.autohideDelay
            autohideAnimationDuration = try c.decodeIfPresent(Double.self, forKey: .autohideAnimationDuration) ?? d.autohideAnimationDuration
            showRecentApplications = try c.decodeIfPresent(Bool.self, forKey: .showRecentApplications) ?? d.showRecentApplications
            showOnlyOpenApplications = try c.decodeIfPresent(Bool.self, forKey: .showOnlyOpenApplications) ?? d.showOnlyOpenApplications
            singleAppMode = try c.decodeIfPresent(Bool.self, forKey: .singleAppMode) ?? d.singleAppMode
            launchAnimation = try c.decodeIfPresent(Bool.self, forKey: .launchAnimation) ?? d.launchAnimation
            showProcessIndicators = try c.decodeIfPresent(Bool.self, forKey: .showProcessIndicators) ?? d.showProcessIndicators
            pinning = try c.decodeIfPresent(String.self, forKey: .pinning) ?? d.pinning
            bouncesOnNotification = try c.decodeIfPresent(Bool.self, forKey: .bouncesOnNotification) ?? d.bouncesOnNotification
            dimsHiddenApps = try c.decodeIfPresent(Bool.self, forKey: .dimsHiddenApps) ?? d.dimsHiddenApps
            groupsWindowsByApp = try c.decodeIfPresent(Bool.self, forKey: .groupsWindowsByApp) ?? d.groupsWindowsByApp
            rearrangesSpacesByUse = try c.decodeIfPresent(Bool.self, forKey: .rearrangesSpacesByUse) ?? d.rearrangesSpacesByUse
            scrollToOpen = try c.decodeIfPresent(Bool.self, forKey: .scrollToOpen) ?? d.scrollToOpen
            springLoadsAllItems = try c.decodeIfPresent(Bool.self, forKey: .springLoadsAllItems) ?? d.springLoadsAllItems
            appSwitcherOnAllDisplays = try c.decodeIfPresent(Bool.self, forKey: .appSwitcherOnAllDisplays) ?? d.appSwitcherOnAllDisplays
            sizeLocked = try c.decodeIfPresent(Bool.self, forKey: .sizeLocked) ?? d.sizeLocked
            positionLocked = try c.decodeIfPresent(Bool.self, forKey: .positionLocked) ?? d.positionLocked
            contentsLocked = try c.decodeIfPresent(Bool.self, forKey: .contentsLocked) ?? d.contentsLocked
            recentAppsCount = try c.decodeIfPresent(Int.self, forKey: .recentAppsCount) ?? d.recentAppsCount
            highlightsStacksOnHover = try c.decodeIfPresent(Bool.self, forKey: .highlightsStacksOnHover) ?? d.highlightsStacksOnHover
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, includesSystemDock, systemDock, docks, theme
    }

    /// Makes a profile that came from a file safe to apply.
    ///
    /// A profile is a document from someone else. Every number is clamped to what
    /// the renderer and the system Dock accept, collections are capped, and every
    /// action tile arrives switched off until the user has read and approved it —
    /// otherwise opening a shared file could run a shell command.
    mutating func sanitizeAsImport() {
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if name.isEmpty { name = "Imported Profile" }
        docks = Array(docks.prefix(12)).map { dock in
            var dock = dock
            dock.id = UUID()
            dock.items = dock.items.map { item in
                var item = item
                item.id = UUID()
                if item.kind == .action { item.isTrusted = false }
                // A shared profile could otherwise label one app as another, or
                // dress it in another app's icon; imported app tiles always show
                // their own name and icon.
                if item.kind == .file, item.path.hasSuffix(".app") { item.customName = nil; item.customIconPath = nil }
                return item
            }
            dock.sanitize()
            return dock
        }
        theme.sanitize()
        systemDock.sanitize()
    }

    /// Whether any tile in this profile will not run until approved.
    var untrustedActionCount: Int {
        docks.reduce(0) { $0 + $1.items.filter { $0.kind == .action && !$0.isTrusted }.count }
    }

    init(
        id: UUID = UUID(),
        name: String,
        includesSystemDock: Bool = true,
        systemDock: SystemDockSettings,
        docks: [SecondaryDock],
        theme: GlassTheme
    ) {
        self.id = id
        self.name = name
        self.includesSystemDock = includesSystemDock
        self.systemDock = systemDock
        self.docks = docks
        self.theme = theme
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        includesSystemDock = try c.decodeIfPresent(Bool.self, forKey: .includesSystemDock) ?? true
        systemDock = try c.decodeIfPresent(SystemDockSettings.self, forKey: .systemDock) ?? SystemDockSettings()
        docks = try c.decodeIfPresent([SecondaryDock].self, forKey: .docks) ?? []
        theme = try c.decodeIfPresent(GlassTheme.self, forKey: .theme) ?? GlassTheme.presets[0]
    }
}
