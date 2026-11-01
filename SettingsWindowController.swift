import SwiftUI
import AppKit

/// Owns the settings window.
///
/// The window is built when it is asked for and released when it closes. The
/// SwiftUI `WindowGroup` it replaces built the whole settings hierarchy at
/// launch and kept it alive for the app's lifetime — memory and start-up time
/// spent on a window most people open a few times a month.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    static let paneKey = "settings.pane"

    private var window: NSWindow?
    private var stores: (dock: SecondaryDockStore, theme: ThemeStore, profile: DockProfileStore, cluster: MenuBarClusterStore, appSense: AppSenseStore)?

    private override init() { super.init() }

    func configure(dock: SecondaryDockStore, theme: ThemeStore, profile: DockProfileStore, cluster: MenuBarClusterStore, appSense: AppSenseStore) {
        stores = (dock, theme, profile, cluster, appSense)
    }

    var isOpen: Bool { window?.isVisible == true }

    func show(pane: ContentView.Pane? = nil) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: Self.paneKey) }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let stores else { return }
        let root = ContentView()
            .environmentObject(stores.dock)
            .environmentObject(stores.theme)
            .environmentObject(stores.profile)
            .environmentObject(stores.cluster)
            .environmentObject(stores.appSense)
        let controller = NSHostingController(rootView: root)
        // The hosting controller would otherwise resize the window to the
        // content's ideal size every time a pane changes.
        controller.sizingOptions = []

        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Dawck"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 880, height: 620)
        window.setContentSize(NSSize(width: 960, height: 720))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("DawckMainWindow")
        if !window.setFrameUsingName("DawckMainWindow") { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // Drop the SwiftUI tree so a closed settings window holds no memory.
        DispatchQueue.main.async { [weak self] in
            self?.window?.contentViewController = nil
            self?.window = nil
        }
    }
}
