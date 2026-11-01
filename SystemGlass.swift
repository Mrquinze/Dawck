import Foundation
import Combine

/// macOS 27's system-wide Liquid Glass appearance slider (System Settings →
/// Appearance): one control, from most clear to most opaque, that restyles the
/// real Dock, sidebars, toolbars and widgets together.
///
/// The slider's value is stored in the global preference domain as
/// `NSGlassTintAmount`. There is no API for apps to read it, but nothing
/// stops them reading the preference — and a floating dock that ignored it
/// would sit next to the real one looking like it came from a different OS.
/// Apple's own glass follows it automatically; this lets Dawck's *custom*
/// glass follow it too.
final class SystemGlass: ObservableObject {
    static let shared = SystemGlass()

    /// 0 is most clear, 1 most opaque. 0.5 is the neutral default, and what
    /// macOS 26 and earlier report, since they have no such setting.
    @Published private(set) var amount: Double = 0.5

    static let key = "NSGlassTintAmount"
    private var observer: NSObjectProtocol?

    private init() {
        amount = Self.read()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let latest = Self.read()
            if abs(latest - self.amount) > 0.0005 { self.amount = latest }
        }
    }

    /// Stored as a string by System Settings ("0.207293"), so read both forms.
    private static func read() -> Double {
        let value = UserDefaults.standard.object(forKey: key)
        let parsed: Double?
        switch value {
        case let number as NSNumber: parsed = number.doubleValue
        case let string as String: parsed = Double(string)
        default: parsed = nil
        }
        guard let parsed, parsed.isFinite else { return 0.5 }
        return min(max(parsed, 0), 1)
    }

    /// How far from neutral the slider sits, -1 (clearest) … +1 (most opaque).
    var bias: Double { (amount - 0.5) * 2 }
}
