import AppKit

enum AppPresentationDefaultsKey {
    static let mode = "appPresentationMode"
    static let menuMode = "menuModeEnabled"
}

/// Dawck's own Dock-icon/menu-bar-item visibility, persisted as this single
/// value (not two independent booleans). Two separate stored flags can't be
/// written atomically — a Picker selection that needs to flip both (e.g. Dock
/// Only -> Menu Bar Only) writes them as two separate `UserDefaults` calls,
/// each posting its own change notification, so an observer can catch them
/// mid-transition with one flag already flipped and the other still stale.
/// That's exactly what made the "never leave both off" safeguard misfire and
/// silently revert the Dock icon back on. A single stored value has no
/// intermediate state to observe.
enum AppPresentationMode: String, CaseIterable, Identifiable {
    case dockOnly, menuBarOnly, both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dockOnly: return "Dock Only"
        case .menuBarOnly: return "Menu Bar Only"
        case .both: return "Dock and Menu Bar"
        }
    }

    var showsDockIcon: Bool { self != .menuBarOnly }
    var showsMenuBarItem: Bool { self != .dockOnly }
}
