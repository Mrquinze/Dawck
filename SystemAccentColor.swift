import Foundation
import AppKit

/// The macOS accent colour — the closest thing to a real "colour" lever
/// anywhere near the Dock, since the Dock itself has none. Setting it is
/// systemwide: every button, checkbox, and selection highlight across every
/// app picks it up immediately, not just the Dock's badges and indicators.
/// That scope is stated up front in the UI, and this is never applied except
/// from the user's own explicit tap on the control that calls it.
enum SystemAccentColor: Int, CaseIterable, Identifiable {
    case multicolor = -2, graphite = -1, red = 0, orange = 1, yellow = 2,
         green = 3, blue = 4, purple = 5, pink = 6

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .multicolor: return "Multicolor"
        case .graphite: return "Graphite"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        }
    }

    var swatch: NSColor {
        switch self {
        case .multicolor: return .controlAccentColor
        case .graphite: return NSColor(white: 0.5, alpha: 1)
        case .red: return NSColor(red: 0.96, green: 0.26, blue: 0.21, alpha: 1)
        case .orange: return NSColor(red: 0.97, green: 0.58, blue: 0.14, alpha: 1)
        case .yellow: return NSColor(red: 0.98, green: 0.80, blue: 0.13, alpha: 1)
        case .green: return NSColor(red: 0.30, green: 0.69, blue: 0.31, alpha: 1)
        case .blue: return NSColor(red: 0.13, green: 0.51, blue: 0.95, alpha: 1)
        case .purple: return NSColor(red: 0.58, green: 0.30, blue: 0.86, alpha: 1)
        case .pink: return NSColor(red: 0.93, green: 0.32, blue: 0.58, alpha: 1)
        }
    }

    static func current() -> SystemAccentColor {
        guard let defaults = UserDefaults(suiteName: UserDefaults.globalDomain) else { return .multicolor }
        // The key is simply absent for Multicolor — there's no dedicated value
        // for "no accent chosen", the absence *is* the setting.
        guard defaults.object(forKey: "AppleAccentColor") != nil else { return .multicolor }
        let raw = defaults.integer(forKey: "AppleAccentColor")
        return SystemAccentColor(rawValue: raw) ?? .multicolor
    }

    /// Writes the systemwide accent colour and asks running apps to pick it
    /// up. There is no public API for "set the accent colour"; System
    /// Settings itself writes this same key. `NSGlobalDomain` is the alias
    /// `defaults` uses for `.GlobalPreferences` — the same domain either way.
    func apply() {
        guard SystemSafety.permit("global AppleAccentColor = \(rawValue)") else { return }
        guard let defaults = UserDefaults(suiteName: UserDefaults.globalDomain) else { return }
        if self == .multicolor {
            defaults.removeObject(forKey: "AppleAccentColor")
        } else {
            defaults.set(rawValue, forKey: "AppleAccentColor")
        }
        // Distributed notification other apps (and this one) listen for to
        // re-read the appearance without a logout — the same one System
        // Settings posts.
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("AppleColorPreferencesChangedNotification"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
