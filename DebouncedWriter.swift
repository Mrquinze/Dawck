import AppKit

/// Coalesces rapid saves into one.
///
/// Every store used to encode and write its JSON on *every* property change,
/// and a slider drag changes a property dozens of times a second — so
/// dragging "Glow Strength" meant dozens of JSON encodes and preference
/// writes (each a round trip to cfprefsd) per second, on the main thread,
/// while the dock panels were also repainting. This waits for a short quiet
/// moment, then writes once. Pending work is flushed when the app resigns
/// active or terminates, so an edit is never lost to the delay.
final class DebouncedWriter {
    private let delay: TimeInterval
    private var pending: (() -> Void)?
    private var work: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    init(delay: TimeInterval = 0.35) {
        self.delay = delay
        let center = NotificationCenter.default
        for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.flush()
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func schedule(_ block: @escaping () -> Void) {
        pending = block
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func flush() {
        work?.cancel()
        work = nil
        let block = pending
        pending = nil
        block?()
    }
}
