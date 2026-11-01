import AppKit
import Combine

/// ExtraBar's "Inline mode": puts each chosen action into the menu bar as its
/// own status item, rather than nesting them all under one icon.
///
/// This is deliberately opt-in per dock. Menu bar space is scarce and shared
/// with every other app on the system, so a dock with twenty tiles must not be
/// able to claim twenty slots because a checkbox defaulted on.
final class InlineActionsManager {
    private let dockStore: SecondaryDockStore
    private var statusItems: [UUID: NSStatusItem] = [:]
    private var cancellables: Set<AnyCancellable> = []

    /// A ceiling on how many items one dock can place. Past roughly this many
    /// the menu bar starts evicting other apps' icons, which is a hostile thing
    /// to do to the rest of the system on the user's behalf.
    private static let maxInlineItems = 12

    init(dockStore: SecondaryDockStore) {
        self.dockStore = dockStore
        reconcile(dockStore.docks)

        dockStore.$docks
            .receive(on: RunLoop.main)
            .sink { [weak self] docks in self?.reconcile(docks) }
            .store(in: &cancellables)
    }

    deinit {
        statusItems.values.forEach { NSStatusBar.system.removeStatusItem($0) }
    }

    /// The tiles that should currently own a menu bar slot, in dock order.
    private func inlineItems(from docks: [SecondaryDock]) -> [(dock: SecondaryDock, item: DockItem)] {
        var result: [(SecondaryDock, DockItem)] = []
        for dock in docks where dock.isEnabled && dock.showsInlineMenuBarItems {
            for item in dock.items where item.kind == .action || item.kind == .file {
                result.append((dock, item))
                if result.count >= Self.maxInlineItems { return result }
            }
        }
        return result
    }

    private func reconcile(_ docks: [SecondaryDock]) {
        let wanted = inlineItems(from: docks)
        let wantedIDs = Set(wanted.map(\.item.id))

        for (id, statusItem) in statusItems where !wantedIDs.contains(id) {
            NSStatusBar.system.removeStatusItem(statusItem)
            statusItems.removeValue(forKey: id)
        }

        for (_, item) in wanted {
            let statusItem = statusItems[item.id] ?? makeStatusItem(for: item)
            statusItems[item.id] = statusItem
            configure(statusItem, for: item)
        }
    }

    private func makeStatusItem(for item: DockItem) -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "DawckInline-\(item.id.uuidString)"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(itemClicked(_:))
        return statusItem
    }

    private func configure(_ statusItem: NSStatusItem, for item: DockItem) {
        guard let button = statusItem.button else { return }
        button.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        button.toolTip = item.displayName

        switch item.kind {
        case .file:
            // The app's real icon, scaled to menu bar height. Not templated —
            // an app icon rendered as a flat silhouette is unrecognisable.
            let icon = IconProvider.shared.icon(forPath: item.path, size: 32)
            let resized = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                icon.draw(in: rect)
                return true
            }
            button.image = resized
        default:
            let image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.displayName)
                ?? NSImage(systemSymbolName: "bolt", accessibilityDescription: item.displayName)
            image?.isTemplate = true
            button.image = image
        }
    }

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        guard let item = dockStore.docks.lazy.flatMap(\.items).first(where: { $0.id == id }) else { return }

        switch item.kind {
        case .action:
            ActionRunner.run(item) { failure in
                guard let failure else { return }
                // A menu bar item has nowhere to show an inline error banner,
                // so a failed action reports through the standard alert path
                // instead of failing silently.
                let alert = NSAlert()
                alert.messageText = "\(item.displayName) didn't run"
                alert.informativeText = failure.errorDescription ?? "Unknown error."
                alert.alertStyle = .warning
                alert.runModal()
            }
        case .file:
            if item.path.hasSuffix(".app") {
                NSWorkspace.shared.openApplication(at: item.url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
            if let bundleID = item.bundleIdentifier, RunningAppsMonitor.shared.activate(bundleID: bundleID) {
                return
            }
            NSWorkspace.shared.open(item.url)
        default:
            break
        }
    }
}
