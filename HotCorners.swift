import Foundation
import AppKit

/// Hot corner actions, stored in `com.apple.dock` as `wvous-<corner>-corner`
/// with a companion `wvous-<corner>-modifier` holding a Carbon modifier mask.
///
/// These live in the Dock's domain because the Dock process owns Mission
/// Control, which is what actually watches the corners.
enum HotCornerAction: Int, CaseIterable, Identifiable {
    case none = 0
    case missionControl = 2
    case applicationWindows = 3
    case desktop = 4
    case startScreenSaver = 5
    case disableScreenSaver = 6
    case notificationCenter = 12
    case launchpad = 11
    case lockScreen = 13
    case quickNote = 14
    case putDisplayToSleep = 10

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: return "Do Nothing"
        case .missionControl: return "Mission Control"
        case .applicationWindows: return "Application Windows"
        case .desktop: return "Desktop"
        case .startScreenSaver: return "Start Screen Saver"
        case .disableScreenSaver: return "Disable Screen Saver"
        case .notificationCenter: return "Notification Center"
        case .launchpad: return "Launchpad"
        case .lockScreen: return "Lock Screen"
        case .quickNote: return "Quick Note"
        case .putDisplayToSleep: return "Put Display to Sleep"
        }
    }
}

/// The modifier that must be held for a corner to fire. Stored as a Carbon
/// event modifier mask, which is why these are raw numbers rather than
/// `NSEvent.ModifierFlags` — the Dock predates that API and still reads the
/// old mask.
enum HotCornerModifier: Int, CaseIterable, Identifiable {
    case none = 0
    case shift = 131072
    case control = 262144
    case option = 524288
    case command = 1048576

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: return "No Modifier"
        case .shift: return "\u{21E7} Shift"
        case .control: return "\u{2303} Control"
        case .option: return "\u{2325} Option"
        case .command: return "\u{2318} Command"
        }
    }
}

enum ScreenCorner: String, CaseIterable, Identifiable {
    case topLeft = "tl", topRight = "tr", bottomLeft = "bl", bottomRight = "br"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    var cornerKey: String { "wvous-\(rawValue)-corner" }
    var modifierKey: String { "wvous-\(rawValue)-modifier" }
}

struct HotCornerSetting: Equatable {
    var action: HotCornerAction = .none
    var modifier: HotCornerModifier = .none
}

enum HotCorners {
    private static let domain = "com.apple.dock" as CFString

    static func read() -> [ScreenCorner: HotCornerSetting] {
        var result: [ScreenCorner: HotCornerSetting] = [:]
        for corner in ScreenCorner.allCases {
            let action = (CFPreferencesCopyAppValue(corner.cornerKey as CFString, domain) as? Int) ?? 0
            let modifier = (CFPreferencesCopyAppValue(corner.modifierKey as CFString, domain) as? Int) ?? 0
            result[corner] = HotCornerSetting(
                action: HotCornerAction(rawValue: action) ?? .none,
                // An unrecognised mask (several modifiers held together, which
                // System Settings can produce) degrades to "no modifier"
                // rather than silently dropping the whole corner.
                modifier: HotCornerModifier(rawValue: modifier) ?? .none
            )
        }
        return result
    }

    static func write(_ settings: [ScreenCorner: HotCornerSetting], restart: Bool = true) {
        for (corner, setting) in settings {
            DockPrefs.set(corner.cornerKey, setting.action.rawValue)
            DockPrefs.set(corner.modifierKey, setting.modifier.rawValue)
        }
        DockPrefs.commit()
        if restart { DockDefaultsManager.restartDock() }
    }
}
