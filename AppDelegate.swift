import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let dockStore = SecondaryDockStore()
    let themeStore = ThemeStore()
    let clusterStore = MenuBarClusterStore()
    let appSenseStore = AppSenseStore()
    lazy var profileStore = DockProfileStore(dockStore: dockStore, themeStore: themeStore)

    private var dockManager: SecondaryDockManager?
    #if BENCH
    /// SwiftUI wraps the delegate it is given, so `NSApp.delegate` is not this object.
    static weak var current: AppDelegate?
    var benchControllers: [DockController] { dockManager?.allControllers ?? [] }
    #endif
    private var clusterManager: MenuBarClusterManager?
    private var inlineActionsManager: InlineActionsManager?
    private var appSenseManager: AppSenseManager?
    private var defaultsObserver: NSObjectProtocol?
    private var isReconciling = false
    private var reconcileAgainRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if BENCH
        AppDelegate.current = self
        #endif
        dockManager = SecondaryDockManager(store: dockStore, themeStore: themeStore) {
            SettingsWindowController.shared.show(pane: .docks)
        }
        clusterManager = MenuBarClusterManager(store: clusterStore)
        inlineActionsManager = InlineActionsManager(dockStore: dockStore)
        appSenseManager = AppSenseManager(store: appSenseStore, profileStore: profileStore)
        SettingsWindowController.shared.configure(dock: dockStore, theme: themeStore, profile: profileStore, cluster: clusterStore, appSense: appSenseStore)
        WelcomeWindowController.shared.configure(dockStore: dockStore)
        BackupManager.shared.configure(dockStore: dockStore, themeStore: themeStore, profileStore: profileStore)
        // A quiet daily safety copy, taken once everything has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { BackupManager.shared.backUp(automatic: true) }
        HotCornerAppWatcher.shared.update(bindings: HotCornerAppBindings.read())
        reconcilePresentation()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reconcilePresentation()
        }
        startHubListener()
        presentInitialWindows()
        #if BENCH
        if ProcessInfo.processInfo.environment["DAWCK_REVEAL_ALL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.benchControllers.forEach { $0.benchReveal() } }
        }
        #endif
        #if BENCH
        DockBenchmark.runIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the app's Dock icon with no window open brings the settings back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !SettingsWindowController.shared.isOpen { SettingsWindowController.shared.show() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Debounced writes must not be lost to a quit.
        dockStore.flush()
        themeStore.flush()
    }

    /// The tour for a new install, "what's new" after an update, and the
    /// settings window as before for anyone who runs Dawck with a Dock icon.
    private func presentInitialWindows() {
        #if BENCH
        if ProcessInfo.processInfo.environment["DAWCK_BENCH"] != nil { return }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let stored = UserDefaults.standard.string(forKey: AppPresentationDefaultsKey.mode)
            let mode = AppPresentationMode(rawValue: stored ?? "") ?? .dockOnly
            WelcomeWindowController.shared.showIfNeeded()
            if mode.showsDockIcon, !WelcomeWindowController.shared.isShowing { SettingsWindowController.shared.show() }
        }
    }

    // MARK: - Hub

    /// Dawck has no URL scheme of its own. "Open" is just a launch, which sends
    /// a reopen event that SwiftUI's `WindowGroup` restores the window from;
    /// menu bar consolidation arrives on `HubMenuBar` instead, which unlike a
    /// URL open can never launch or replace this process.
    private func startHubListener() {
        HubMenuBar.start { [weak self] visible in
            HubPresentation.shared.suppressesMenuBarItem = !visible
            // The hub's suppression flag lives in memory, not UserDefaults, so
            // it never fires the didChangeNotification reconcilePresentation()
            // otherwise relies on. Without this call, a hub suppression
            // arriving while the mode is Menu Bar Only would leave the Dock
            // icon fallback un-evaluated — no Dock icon, no menu bar item, no
            // window: the app would look exactly like it crashed while still
            // quietly running.
            self?.reconcilePresentation()
        }
    }

    /// Applies the Dock icon policy for the current `AppPresentationMode`.
    /// This stays entirely outside SwiftUI's view graph — calling
    /// `NSApp.setActivationPolicy` from a SwiftUI onChange/onAppear can crash
    /// with an AttributeGraph "setting value during update" error, since it can
    /// trigger window reconfiguration while SwiftUI's own graph update is still
    /// running. Reaching this via the `UserDefaults.didChangeNotification`
    /// observer's `queue: .main` delivery already provides that escape (it's a
    /// full run-loop turn away from whatever wrote the default), so no
    /// additional `DispatchQueue.main.async` hop is needed.
    /// If a second call arrives while one is already running, it's not simply
    /// dropped — that would risk leaving the app on a stale decision if defaults
    /// changed again in between. It's coalesced into one more pass immediately
    /// after the current one finishes, so the last write always wins.
    private func reconcilePresentation() {
        guard !isReconciling else {
            reconcileAgainRequested = true
            return
        }
        isReconciling = true
        applyCurrentPresentation()
        isReconciling = false

        if reconcileAgainRequested {
            reconcileAgainRequested = false
            reconcilePresentation()
        }
    }

    private func applyCurrentPresentation() {
        let stored = UserDefaults.standard.string(forKey: AppPresentationDefaultsKey.mode)
        let mode = AppPresentationMode(rawValue: stored ?? "") ?? .dockOnly

        // The hub can suppress the menu bar item independently of the stored
        // mode. If Menu Bar Only is the only way this mode reaches the user and
        // the hub is currently hiding it, fall back to showing the Dock icon so
        // the app is never invisible everywhere at once. This is a live,
        // reactive fallback computed fresh each time — it never writes to the
        // stored mode, so the menu bar item takes back over on its own the
        // moment the hub stops suppressing it.
        let menuBarActuallyVisible = mode.showsMenuBarItem && !HubPresentation.shared.suppressesMenuBarItem
        let showDock = mode.showsDockIcon || !menuBarActuallyVisible

        let desiredPolicy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        guard NSApp.activationPolicy() != desiredPolicy else { return }
        NSApp.setActivationPolicy(desiredPolicy)
        if desiredPolicy == .regular {
            // Nudges the Dock to reflect the icon right away — switching back
            // to .regular can otherwise sit unreflected for a beat.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }
}
