import AppKit
import Combine

/// Tracks which applications are running, and which of them have a window on
/// the Space the user is currently looking at.
///
/// There is no public API that reports "apps in the current Space". The
/// approximation used here is `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`,
/// which returns exactly the windows composited on the *current* Space, mapped
/// back to owning process IDs. Only PIDs and layers are read — never window
/// titles — so this needs no Screen Recording permission.
///
/// The set of running apps is notification-driven and republished only when the
/// set itself changes (an app being activated no longer causes a refresh of
/// every dock). Space membership is the part that costs a repeating read, so it
/// runs only for docks that filter by Space.
final class RunningAppsMonitor: ObservableObject {
    static let shared = RunningAppsMonitor()

    /// Bundle identifiers of every regular (Dock-showing) app that is running.
    @Published private(set) var running: Set<String> = []
    /// Bundle identifiers with at least one window on the current Space.
    @Published private(set) var bundleIDsInCurrentSpace: Set<String> = []
    /// Whether the last Space reading looked like real data. If a future OS
    /// tightens the window list, an empty reading while apps are running is
    /// treated as unusable and callers fall back to the running-apps filter.
    @Published private(set) var isSpaceDataUsable = true

    private var observers: [NSObjectProtocol] = []
    private var spaceTimer: DispatchSourceTimer?
    private var subscribers = 0
    private var spaceSubscribers = 0

    private init() {}

    func start(trackingSpaces: Bool = false) {
        subscribers += 1
        if trackingSpaces {
            spaceSubscribers += 1
            startSpaceTrackingIfNeeded()
        }
        guard observers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshRunning() })
        }
        // The window list is only accurate after the Space-switch animation settles.
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let self, self.spaceSubscribers > 0 else { return }
                self.refreshSpace()
            }
        })
        refreshRunning()
    }

    private func startSpaceTrackingIfNeeded() {
        guard spaceTimer == nil, spaceSubscribers > 0 else { return }
        refreshSpace()
        // Windows move between Spaces without any notification firing, so
        // membership needs a slow poll as a backstop — only while a dock is
        // actually filtering by Space.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3, leeway: .milliseconds(800))
        timer.setEventHandler { [weak self] in self?.refreshSpace() }
        timer.resume()
        spaceTimer = timer
    }

    func stop(trackingSpaces: Bool = false) {
        subscribers = max(0, subscribers - 1)
        if trackingSpaces {
            spaceSubscribers = max(0, spaceSubscribers - 1)
            if spaceSubscribers == 0 { spaceTimer?.cancel(); spaceTimer = nil }
        }
        guard subscribers == 0 else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        spaceTimer?.cancel()
        spaceTimer = nil
        spaceSubscribers = 0
    }

    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }

    /// Brings an already-running app forward instead of asking LaunchServices
    /// to open it again.
    @discardableResult
    func activate(bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        return app.activate(options: [.activateAllWindows])
    }

    private func refreshRunning() {
        let ids = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
        if ids != running { running = ids }
    }

    private func refreshSpace() {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        var pids = Set<pid_t>()
        for window in windows {
            // Layer 0 is the normal window layer; anything above is a panel,
            // menu, or the Dock itself.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            pids.insert(pid)
        }
        let updated = Set(NSWorkspace.shared.runningApplications.filter { pids.contains($0.processIdentifier) }.compactMap(\.bundleIdentifier))
        let usable = !updated.isEmpty || running.isEmpty
        if usable != isSpaceDataUsable { isSpaceDataUsable = usable }
        if updated != bundleIDsInCurrentSpace { bundleIDsInCurrentSpace = updated }
    }
}
