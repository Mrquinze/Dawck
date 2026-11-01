import SwiftUI

@main
struct DawckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppPresentationDefaultsKey.mode) private var presentationModeRaw = AppPresentationMode.dockOnly.rawValue
    @AppStorage(AppPresentationDefaultsKey.menuMode) private var menuModeEnabled = true
    @ObservedObject private var hub = HubPresentation.shared

    private var presentationMode: AppPresentationMode {
        AppPresentationMode(rawValue: presentationModeRaw) ?? .dockOnly
    }

    var body: some Scene {
        MenuBarExtra(
            "Dawck",
            systemImage: "square.stack.3d.down.right",
            isInserted: Binding(
                get: { presentationMode.showsMenuBarItem && !hub.suppressesMenuBarItem },
                set: { isInserted in
                    // `isInserted` reads false for two very different reasons:
                    // the hub is suppressing the icon (expected, temporary,
                    // nothing to do with the user's chosen mode), or the user
                    // removed it via the system's own "Remove from Menu Bar"
                    // gesture (a real, standing choice). Only the latter should
                    // fall back to Dock Only — otherwise, every time the hub
                    // suppresses the item, this would stomp the user's Menu Bar
                    // Only / Both selection back to Dock Only the moment they
                    // picked it, since the hub is already suppressing by then.
                    guard !isInserted, !hub.suppressesMenuBarItem else { return }
                    presentationModeRaw = AppPresentationMode.dockOnly.rawValue
                }
            )
        ) {
            MenuBarContent(
                dockStore: appDelegate.dockStore,
                profileStore: appDelegate.profileStore,
                clusterStore: appDelegate.clusterStore,
                menuModeEnabled: menuModeEnabled,
                openMainWindow: { SettingsWindowController.shared.show() },
                openWelcome: { WelcomeWindowController.shared.show(force: true) }
            )
        }
    }
}

/// The menu bar item's contents. In Menu Mode this is a full command centre —
/// every dock's action tiles are runnable from here, so a user who prefers no
/// floating panels at all still has one-click access to everything.
private struct MenuBarContent: View {
    @ObservedObject var dockStore: SecondaryDockStore
    @ObservedObject var profileStore: DockProfileStore
    @ObservedObject var clusterStore: MenuBarClusterStore
    let menuModeEnabled: Bool
    let openMainWindow: () -> Void
    let openWelcome: () -> Void

    var body: some View {
        Button("Open Dawck") { openMainWindow() }
            .keyboardShortcut("d")
        Button("What's New & Getting Started…") { openWelcome() }

        if menuModeEnabled {
            if !profileStore.profiles.isEmpty {
                Divider()
                Menu("Profiles") {
                    ForEach(profileStore.profiles) { profile in
                        Button {
                            profileStore.apply(profile)
                        } label: {
                            // A leading checkmark rather than `Toggle`, so the
                            // row still reads as an action — applying a profile
                            // isn't something you switch off again.
                            Text(profileStore.activeProfileID == profile.id ? "\u{2713}  \(profile.name)" : "    \(profile.name)")
                        }
                    }
                }
            }

            if !clusterStore.clusters.isEmpty {
                Divider()
                Menu("Menu Bar Clusters") {
                    ForEach(clusterStore.clusters) { cluster in
                        Button {
                            clusterStore.toggle(cluster.id)
                        } label: {
                            Text(cluster.isCollapsed ? "Reveal \(cluster.name)" : "Hide \(cluster.name)")
                        }
                    }
                    Divider()
                    Button("Reveal All") { clusterStore.revealAll() }
                    Button("Hide All") { clusterStore.collapseAll() }
                }
            }

            if !dockStore.docks.isEmpty {
                Divider()
                ForEach(dockStore.docks) { dock in
                    Menu(dock.name) {
                        Button(dock.isEnabled ? "Hide This Dock" : "Show This Dock") {
                            var updated = dock
                            updated.isEnabled.toggle()
                            dockStore.update(updated)
                        }

                        let runnable = dock.items.filter { $0.kind == .action || $0.kind == .file }
                        if !runnable.isEmpty {
                            Divider()
                            ForEach(runnable) { item in
                                Button(item.displayName) { run(item) }
                            }
                        }
                    }
                }
            }
        }

        Divider()
        Button("Quit Dawck") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func run(_ item: DockItem) {
        switch item.kind {
        case .action:
            ActionRunner.run(item)
        case .file:
            if item.path.hasSuffix(".app") {
                NSWorkspace.shared.openApplication(at: item.url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(item.url)
            }
        default:
            break
        }
    }
}
