import AppKit

/// Watches other apps' windows for the docks that step aside — when a window
/// covers them, or when an app goes full screen.
///
/// macOS posts no notification when another app's window moves, so this reads
/// the window list at the moments it can change (an app or Space switch, the end
/// or middle of a drag, a display change) with a slow timer as a backstop. It
/// runs only while some dock has asked for it, reads only frames and owners
/// (never titles, so no Screen Recording permission), and tells its observers
/// only when the picture has actually changed.
final class WindowObserver {
    static let shared = WindowObserver()

    struct Snapshot: Equatable {
        /// Frames of ordinary windows belonging to other apps, in screen coordinates.
        var frames: [CGRect] = []
        /// Displays on which one window fills the whole screen.
        var fullscreenDisplays: Set<Int> = []
    }

    private var handlers: [ObjectIdentifier: (Snapshot) -> Void] = [:]
    private var latest = Snapshot()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var backstop: DispatchSourceTimer?
    private var lastDragCheck: CFAbsoluteTime = 0
    private var pending = false

    private init() {}

    func register(_ owner: AnyObject, handler: @escaping (Snapshot) -> Void) {
        handlers[ObjectIdentifier(owner)] = handler
        if handlers.count == 1 { install() }
        handler(latest)
        check()
    }

    func unregister(_ owner: AnyObject) {
        handlers[ObjectIdentifier(owner)] = nil
        if handlers.isEmpty { uninstall() }
    }

    private func install() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleCheck(after: 0.05) })
        }
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleCheck(after: 0.4)
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleCheck(after: 0.3)
        })
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in self?.scheduleCheck(after: 0.05) }) { monitors.append(up) }
        if let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            // A window being dragged: sample at ~8 Hz rather than per event.
            let now = CFAbsoluteTimeGetCurrent()
            guard let self, now - self.lastDragCheck > 0.12 else { return }
            self.lastDragCheck = now
            self.check()
        }) { monitors.append(drag) }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        backstop = timer
    }

    private func uninstall() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers = []
        backstop?.cancel()
        backstop = nil
    }

    private func scheduleCheck(after delay: TimeInterval) {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.pending = false
            self?.check()
        }
    }

    private func check() {
        guard !handlers.isEmpty else { return }
        let snapshot = Self.read()
        guard snapshot != latest else { return }
        latest = snapshot
        for handler in handlers.values { handler(snapshot) }
    }

    private static func read() -> Snapshot {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return Snapshot() }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var snapshot = Snapshot()
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? pid_t) != myPID,
                  ((window[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                  w >= 40, h >= 40 else { continue }
            // CoreGraphics measures from the top-left of the primary display; AppKit from the bottom-left.
            snapshot.frames.append(CGRect(x: x, y: primaryHeight - y - h, width: w, height: h))
        }
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let target = screen.frame
            if snapshot.frames.contains(where: { abs($0.minX - target.minX) < 2 && abs($0.minY - target.minY) < 2
                                                   && abs($0.width - target.width) < 2 && abs($0.height - target.height) < 2 }) {
                snapshot.fullscreenDisplays.insert(id)
            }
        }
        return snapshot
    }
}
