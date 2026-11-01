import AppKit

/// Tells every dock where the pointer is, without a timer.
///
/// The old build polled the pointer at 20 Hz for as long as any dock could
/// collapse — thousands of wakeups an hour for nothing, and, because Dawck is
/// an accessory app whose faded docks count as invisible, App Nap coalesced
/// those timers so the reveal could arrive up to a second late. Event monitors
/// fire only when the pointer actually moves, wake a napping app immediately,
/// and cost nothing while the pointer is still.
///
/// Global monitors see pointer movement over *other* apps' windows; local ones
/// see it over our own. Both are needed, since a dock's window stops getting
/// events when it is click-through.
final class DockPointerHub {
    static let shared = DockPointerHub()

    private var global: Any?
    private var local: Any?
    private var handlers: [ObjectIdentifier: (NSPoint) -> Void] = [:]

    private init() {}

    func register(_ owner: AnyObject, handler: @escaping (NSPoint) -> Void) {
        handlers[ObjectIdentifier(owner)] = handler
        installIfNeeded()
    }

    func unregister(_ owner: AnyObject) {
        handlers[ObjectIdentifier(owner)] = nil
        if handlers.isEmpty { uninstall() }
    }

    private func installIfNeeded() {
        guard global == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.fire() }
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.fire()
            return event
        }
    }

    private func uninstall() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
    }

    /// Poke every dock with the current pointer position (also used after a
    /// dock changes, so it re-evaluates without waiting for a movement).
    func fire() {
        let point = NSEvent.mouseLocation
        for handler in handlers.values { handler(point) }
    }
}
