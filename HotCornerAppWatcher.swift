import AppKit
import Combine

/// Lets a hot corner open a chosen app instead of a native macOS action.
///
/// There is no `wvous-*-corner` code for "launch this app" — the four
/// integers macOS understands (Mission Control, Desktop, the screen saver
/// actions, and the rest) are a fixed, closed set owned by the Dock process,
/// and none of them takes a payload. Making a corner launch an arbitrary app
/// therefore can't be done by writing a preference and asking macOS to do it;
/// Dawck has to watch the corner itself and act when the pointer arrives.
///
/// A corner with an app assigned has its native `wvous-*-corner` written to
/// `.none` — see `HotCorners.write` — so the OS doesn't also try to do
/// something at the same spot. This watcher is the entire replacement.
final class HotCornerAppWatcher {
    /// Which corners currently have an armed trigger.
    private var bindings: [ScreenCorner: String] = [:]
    /// Whether the pointer was already inside each corner at the previous
    /// movement. The launch fires on the *entering* edge, mirroring how macOS's
    /// own corners work — pushing in once launches once; sitting in the corner
    /// does not relaunch.
    private var wasInside: Set<ScreenCorner> = []

    static let shared = HotCornerAppWatcher()
    private init() {}

    /// Side length of the square hit region at each corner, in points.
    private static let hitSize: CGFloat = 4

    /// Driven by pointer movement, not a timer: a watcher that polled 15 times a
    /// second woke the process 54,000 times an hour to watch a pointer that was,
    /// nearly always, nowhere near a corner.
    func update(bindings: [ScreenCorner: String]) {
        self.bindings = bindings
        wasInside.removeAll()
        if bindings.isEmpty {
            DockPointerHub.shared.unregister(self)
        } else {
            DockPointerHub.shared.register(self) { [weak self] point in self?.pointerMoved(point) }
        }
    }

    private func pointerMoved(_ pointer: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else { return }
        // Quick reject: nothing to do unless the pointer is near a screen corner.
        let frame = screen.frame
        let margin = Self.hitSize + 2
        guard pointer.x < frame.minX + margin || pointer.x > frame.maxX - margin,
              pointer.y < frame.minY + margin || pointer.y > frame.maxY - margin || !wasInside.isEmpty else {
            if !wasInside.isEmpty { wasInside.removeAll() }
            return
        }

        // macOS 27: a full-screen game or presentation can ask the system to
        // switch hot corners off. Corners that launch apps respect that too.
        var suppressed = false
        if #available(macOS 27.0, *) {
            suppressed = NSApp.currentSystemPresentationOptions.contains(.disableScreenCornerInteractions)
        }

        for (corner, path) in bindings {
            let inside = Self.hitRect(for: corner, on: screen).contains(pointer)
            let wasInsideBefore = wasInside.contains(corner)
            if inside && !wasInsideBefore && !suppressed {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            if inside { wasInside.insert(corner) } else { wasInside.remove(corner) }
        }
    }

    private static func hitRect(for corner: ScreenCorner, on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        switch corner {
        case .topLeft:
            return NSRect(x: frame.minX, y: frame.maxY - hitSize, width: hitSize, height: hitSize)
        case .topRight:
            return NSRect(x: frame.maxX - hitSize, y: frame.maxY - hitSize, width: hitSize, height: hitSize)
        case .bottomLeft:
            return NSRect(x: frame.minX, y: frame.minY, width: hitSize, height: hitSize)
        case .bottomRight:
            return NSRect(x: frame.maxX - hitSize, y: frame.minY, width: hitSize, height: hitSize)
        }
    }
}

/// Persists which corners open an app, separate from `HotCorners`'s native
/// `com.apple.dock` storage — this is Dawck's own state, since macOS has
/// nowhere to keep it.
enum HotCornerAppBindings {
    private static let key = "hotCornerAppBindings"

    static func read() -> [ScreenCorner: String] {
        guard let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return [:] }
        var result: [ScreenCorner: String] = [:]
        for (rawCorner, path) in dict {
            guard let corner = ScreenCorner(rawValue: rawCorner) else { continue }
            result[corner] = path
        }
        return result
    }

    static func write(_ bindings: [ScreenCorner: String]) {
        var dict: [String: String] = [:]
        for (corner, path) in bindings { dict[corner.rawValue] = path }
        UserDefaults.standard.set(dict, forKey: key)
        HotCornerAppWatcher.shared.update(bindings: bindings)
    }
}
