import Foundation

enum DockPosition: String, CaseIterable, Identifiable {
    case bottom, left, right
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottom: return "Bottom"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

enum DockMinimizeEffect: String, CaseIterable, Identifiable {
    case genie, scale, suck
    var id: String { rawValue }
    var label: String {
        switch self {
        case .genie: return "Genie"
        case .scale: return "Scale"
        case .suck: return "Suck"
        }
    }
}

/// Where along its edge the Dock sits. Only has a visible effect when the Dock
/// is narrower than the edge it lives on.
enum DockPinning: String, CaseIterable, Identifiable {
    case start, middle, end
    var id: String { rawValue }
    var label: String {
        switch self {
        case .start: return "Start"
        case .middle: return "Middle"
        case .end: return "End"
        }
    }
}

/// Typed access to the `com.apple.dock` preference domain.
///
/// Reads and writes go through CFPreferences rather than shelling out to
/// `/usr/bin/defaults`. The shell route spawned a process per key — a full
/// settings load was twenty-odd launches — and `defaults` is itself a thin
/// wrapper over the same call. Every write passes through `SystemSafety`.
enum DockPrefs {
    static let domain = "com.apple.dock" as CFString

    static func raw(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    static func bool(_ key: String, default fallback: Bool) -> Bool {
        switch raw(key) {
        case let number as NSNumber: return number.boolValue
        case let string as String: return ["1", "true", "yes"].contains(string.lowercased())
        default: return fallback
        }
    }

    static func double(_ key: String, default fallback: Double) -> Double {
        switch raw(key) {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string) ?? fallback
        default: return fallback
        }
    }

    static func int(_ key: String, default fallback: Int) -> Int {
        switch raw(key) {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string) ?? fallback
        default: return fallback
        }
    }

    static func string(_ key: String, default fallback: String) -> String {
        (raw(key) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }

    /// Stages a value. Nothing is visible to the Dock until `commit()`.
    static func set(_ key: String, _ value: Any?) {
        guard SystemSafety.permit("com.apple.dock \(key) = \(String(describing: value))") else { return }
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
    }

    static func commit() {
        guard SystemSafety.allowsSystemWrites else { return }
        CFPreferencesAppSynchronize(domain)
    }
}

/// Reads and writes the `com.apple.dock` preference domain and restarts the Dock
/// process so changes take visible effect.
enum DockDefaultsManager {

    static func restartDock() {
        guard SystemSafety.permit("killall Dock") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    struct Settings {
        var tileSize: Double
        var magnificationEnabled: Bool
        var magnifiedTileSize: Double
        var position: DockPosition
        var minimizeEffect: DockMinimizeEffect
        var minimizeToApplication: Bool
        var autohide: Bool
        var autohideDelay: Double
        var autohideAnimationDuration: Double
        var showRecentApplications: Bool
        var showOnlyOpenApplications: Bool
        var singleAppMode: Bool
        var launchAnimation: Bool
        var showProcessIndicators: Bool

        // Added in 2.2
        var pinning: DockPinning
        var bouncesOnNotification: Bool
        var dimsHiddenApps: Bool
        var groupsWindowsByApp: Bool
        var rearrangesSpacesByUse: Bool
        var scrollToOpen: Bool
        var springLoadsAllItems: Bool
        var appSwitcherOnAllDisplays: Bool
        var sizeLocked: Bool
        var positionLocked: Bool
        var contentsLocked: Bool

        // Added in 3.0
        /// How many recently used apps the Dock shows (`show-recent-count`).
        var recentAppsCount: Int
        /// Highlights a stack's items as the pointer passes over it
        /// (`mouse-over-hilite-stack`).
        var highlightsStacksOnHover: Bool
    }

    static func loadCurrentSettings() -> Settings {
        Settings(
            tileSize: DockPrefs.double("tilesize", default: 48),
            magnificationEnabled: DockPrefs.bool("magnification", default: false),
            magnifiedTileSize: DockPrefs.double("largesize", default: 64),
            position: DockPosition(rawValue: DockPrefs.string("orientation", default: "bottom")) ?? .bottom,
            minimizeEffect: DockMinimizeEffect(rawValue: DockPrefs.string("mineffect", default: "genie")) ?? .genie,
            minimizeToApplication: DockPrefs.bool("minimize-to-application", default: false),
            autohide: DockPrefs.bool("autohide", default: false),
            autohideDelay: DockPrefs.double("autohide-delay", default: 0.5),
            autohideAnimationDuration: DockPrefs.double("autohide-time-modifier", default: 0.5),
            showRecentApplications: DockPrefs.bool("show-recents", default: true),
            showOnlyOpenApplications: DockPrefs.bool("static-only", default: false),
            singleAppMode: DockPrefs.bool("single-app", default: false),
            launchAnimation: DockPrefs.bool("launchanim", default: true),
            showProcessIndicators: DockPrefs.bool("show-process-indicators", default: true),
            pinning: DockPinning(rawValue: DockPrefs.string("pinning", default: "middle")) ?? .middle,
            // Stored inverted: the Dock's key is `no-bouncing`, but a settings
            // row that reads "Bounce on notification" is far clearer than one
            // that reads "No bouncing" and has to be mentally negated.
            bouncesOnNotification: !DockPrefs.bool("no-bouncing", default: false),
            dimsHiddenApps: DockPrefs.bool("showhidden", default: false),
            groupsWindowsByApp: DockPrefs.bool("expose-group-apps", default: false),
            rearrangesSpacesByUse: DockPrefs.bool("mru-spaces", default: true),
            scrollToOpen: DockPrefs.bool("scroll-to-open", default: false),
            springLoadsAllItems: DockPrefs.bool("enable-spring-load-actions-on-all-items", default: false),
            appSwitcherOnAllDisplays: DockPrefs.bool("appswitcher-all-displays", default: false),
            sizeLocked: DockPrefs.bool("size-immutable", default: false),
            positionLocked: DockPrefs.bool("position-immutable", default: false),
            contentsLocked: DockPrefs.bool("contents-immutable", default: false),
            recentAppsCount: DockPrefs.int("show-recent-count", default: 3),
            highlightsStacksOnHover: DockPrefs.bool("mouse-over-hilite-stack", default: false)
        )
    }

    static var fallbackSettings: Settings {
        Settings(
            tileSize: 48,
            magnificationEnabled: false,
            magnifiedTileSize: 64,
            position: .bottom,
            minimizeEffect: .genie,
            minimizeToApplication: false,
            autohide: false,
            autohideDelay: 0.5,
            autohideAnimationDuration: 0.5,
            showRecentApplications: true,
            showOnlyOpenApplications: false,
            singleAppMode: false,
            launchAnimation: true,
            showProcessIndicators: true,
            pinning: .middle,
            bouncesOnNotification: true,
            dimsHiddenApps: false,
            groupsWindowsByApp: false,
            rearrangesSpacesByUse: true,
            scrollToOpen: false,
            springLoadsAllItems: false,
            appSwitcherOnAllDisplays: false,
            sizeLocked: false,
            positionLocked: false,
            contentsLocked: false,
            recentAppsCount: 3,
            highlightsStacksOnHover: false
        )
    }

    static func apply(_ settings: Settings) {
        DockPrefs.set("tilesize", settings.tileSize)
        DockPrefs.set("magnification", settings.magnificationEnabled)
        DockPrefs.set("largesize", settings.magnifiedTileSize)
        DockPrefs.set("orientation", settings.position.rawValue)
        DockPrefs.set("mineffect", settings.minimizeEffect.rawValue)
        DockPrefs.set("minimize-to-application", settings.minimizeToApplication)
        DockPrefs.set("autohide", settings.autohide)
        DockPrefs.set("autohide-delay", settings.autohideDelay)
        DockPrefs.set("autohide-time-modifier", settings.autohideAnimationDuration)
        DockPrefs.set("show-recents", settings.showRecentApplications)
        DockPrefs.set("static-only", settings.showOnlyOpenApplications)
        DockPrefs.set("single-app", settings.singleAppMode)
        DockPrefs.set("launchanim", settings.launchAnimation)
        DockPrefs.set("show-process-indicators", settings.showProcessIndicators)
        DockPrefs.set("pinning", settings.pinning.rawValue)
        DockPrefs.set("no-bouncing", !settings.bouncesOnNotification)
        DockPrefs.set("showhidden", settings.dimsHiddenApps)
        DockPrefs.set("expose-group-apps", settings.groupsWindowsByApp)
        DockPrefs.set("mru-spaces", settings.rearrangesSpacesByUse)
        DockPrefs.set("scroll-to-open", settings.scrollToOpen)
        DockPrefs.set("enable-spring-load-actions-on-all-items", settings.springLoadsAllItems)
        DockPrefs.set("appswitcher-all-displays", settings.appSwitcherOnAllDisplays)
        DockPrefs.set("show-recent-count", settings.recentAppsCount)
        DockPrefs.set("mouse-over-hilite-stack", settings.highlightsStacksOnHover)
        // The lock switches are written last. `contents-immutable` makes the
        // Dock reject tile changes, so writing it before the others would make
        // this very call the first thing it blocks.
        DockPrefs.set("size-immutable", settings.sizeLocked)
        DockPrefs.set("position-immutable", settings.positionLocked)
        DockPrefs.set("contents-immutable", settings.contentsLocked)
        DockPrefs.commit()
        restartDock()
    }

    /// Reads just the three autohide keys, independent of the full `Settings`
    /// struct — used by `SystemDockReplacement` so hiding the Dock for a
    /// replacement doesn't have to round-trip (and risk perturbing) every
    /// other Dock setting just to touch these three.
    struct AutohideState: Codable, Equatable {
        var autohide: Bool
        var delay: Double
        var timeModifier: Double
    }

    static func readAutohideState() -> AutohideState {
        AutohideState(
            autohide: DockPrefs.bool("autohide", default: false),
            delay: DockPrefs.double("autohide-delay", default: 0.5),
            timeModifier: DockPrefs.double("autohide-time-modifier", default: 0.5)
        )
    }

    static func writeAutohideState(_ state: AutohideState, restart: Bool = true) {
        DockPrefs.set("autohide", state.autohide)
        DockPrefs.set("autohide-delay", state.delay)
        DockPrefs.set("autohide-time-modifier", state.timeModifier)
        DockPrefs.commit()
        if restart { restartDock() }
    }

    enum SpacerSize {
        case small, large
    }

    /// Appends a spacer tile to the Dock's persistent app list. There is no
    /// supported public API for it; this is the same plist edit every Dock
    /// tool performs.
    static func addSpacer(_ size: SpacerSize) {
        SystemDockItems.addSpacer(small: size == .small, to: .apps)
    }
}
