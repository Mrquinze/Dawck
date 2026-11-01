import AppKit
import Combine

/// Owns a `DockController` for every enabled dock (one per display for docks
/// that appear on all screens) and keeps them in step with the stores. Lives for
/// the app's lifetime so docks stay on screen when the settings window is closed.
final class SecondaryDockManager {
    private struct Key: Hashable {
        let dock: UUID
        let target: DockScreenTarget
    }

    private let store: SecondaryDockStore
    private let themeStore: ThemeStore
    private let environment: DockEnvironment

    private var controllers: [Key: DockController] = [:]
    private var applied: [Key: (dock: SecondaryDock, theme: GlassTheme)] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var screenWork: DispatchWorkItem?

    /// Which shared services this manager has asked to run, so each is started
    /// and stopped exactly once however many docks want it.
    private var wantsRunningApps = false
    private var wantsSpaceTracking = false
    private var wantsLiveDock = false

    init(store: SecondaryDockStore, themeStore: ThemeStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.themeStore = themeStore
        self.environment = DockEnvironment(store: store, themeStore: themeStore, openSettings: openSettings)

        reconcile()

        // Docks and themes change in bursts while a slider is dragged; one pass
        // per main-loop turn is plenty, and each controller coalesces further.
        store.$docks.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.reconcile() }.store(in: &cancellables)
        themeStore.$active.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.reconcile() }.store(in: &cancellables)
        themeStore.$saved.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.reconcile() }.store(in: &cancellables)

        // What the tiles reflect.
        RunningAppsMonitor.shared.$running.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshAll() }.store(in: &cancellables)
        RunningAppsMonitor.shared.$bundleIDsInCurrentSpace.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshAll() }.store(in: &cancellables)
        SystemDockReader.shared.$items.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshAll() }.store(in: &cancellables)

        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        })
        // After sleep the displays can come back in a different order or size.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged(delay: 1.2)
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        controllers.values.forEach { $0.teardown() }
        if wantsRunningApps { RunningAppsMonitor.shared.stop(trackingSpaces: wantsSpaceTracking) }
        if wantsLiveDock { SystemDockReader.shared.stop() }
    }

    var allControllers: [DockController] { Array(controllers.values) }

    // MARK: Reconciliation

    private func targets(for dock: SecondaryDock) -> [DockScreenTarget] {
        guard dock.showsOnAllScreens else { return [.dockDisplay] }
        let screens = NSScreen.screens.compactMap(\.displayID).map(DockScreenTarget.display)
        return screens.isEmpty ? [.dockDisplay] : screens
    }

    private func reconcile() {
        let enabled = store.docks.filter(\.isEnabled)
        var wanted: [Key: SecondaryDock] = [:]
        for dock in enabled { for target in targets(for: dock) { wanted[Key(dock: dock.id, target: target)] = dock } }

        for (key, controller) in controllers where wanted[key] == nil {
            controller.teardown()
            controllers[key] = nil
            applied[key] = nil
        }
        for (key, dock) in wanted {
            let theme = themeStore.theme(for: dock.themeOverrideID)
            if let controller = controllers[key] {
                if let last = applied[key], last.dock == dock, last.theme == theme { continue }
                controller.update(dock: dock, theme: theme)
            } else {
                controllers[key] = DockController(dock: dock, target: key.target, theme: theme, env: environment)
            }
            applied[key] = (dock, theme)
        }
        updateServices(for: enabled)
    }

    private func refreshAll() { controllers.values.forEach { $0.requestRefresh() } }

    /// Starts only the background services some dock actually needs, and stops
    /// them when the last dock needing one is disabled or reconfigured.
    private func updateServices(for docks: [SecondaryDock]) {
        let needsRunningApps = docks.contains { $0.contentMode.needsRunningApps || $0.showsRunningIndicators || $0.dimsNonRunningApps }
        let needsSpaces = docks.contains { $0.contentMode == .currentSpace }
        if needsRunningApps != wantsRunningApps || needsSpaces != wantsSpaceTracking {
            if wantsRunningApps { RunningAppsMonitor.shared.stop(trackingSpaces: wantsSpaceTracking) }
            if needsRunningApps { RunningAppsMonitor.shared.start(trackingSpaces: needsSpaces) }
            wantsRunningApps = needsRunningApps
            wantsSpaceTracking = needsSpaces
        }
        let needsLiveDock = docks.contains { $0.contentMode == .liveDock }
        if needsLiveDock != wantsLiveDock {
            wantsLiveDock = needsLiveDock
            needsLiveDock ? SystemDockReader.shared.start() : SystemDockReader.shared.stop()
        }
    }

    // MARK: Displays

    private func screensChanged(delay: TimeInterval = 0.3) {
        screenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Docks on every screen need controllers for the screens that exist now.
            self.reconcile()
            self.controllers.values.forEach { $0.reposition(); $0.requestRefresh() }
        }
        screenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
