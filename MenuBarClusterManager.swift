import AppKit
import Combine

/// Owns one `NSStatusItem` per cluster and folds menu bar icons away by
/// widening it.
///
/// ## How folding actually works
///
/// macOS lays status items out right to left from the screen's right edge. An
/// item's right edge is anchored where the system put it; growing its `length`
/// therefore extends it *leftward*, shoving every item to its left further left
/// — off the screen entirely, if it grows enough. That is the whole mechanism,
/// and it is the only one available without Accessibility: no public API lets
/// one app read, move, or hide another app's status item.
///
/// ## Why clusters nest instead of being independent
///
/// A consequence worth being blunt about: because growing an item only pushes
/// what is to its *left*, folding a cluster necessarily hides every cluster
/// further left as well. Clusters are therefore nested, outermost on the right.
/// This is not a shortcut a cleverer implementation would avoid — it falls
/// straight out of how the menu bar lays itself out. Bartender works around it
/// by driving the Accessibility API, which is exactly the permission this app
/// is built to do without.
///
/// What Dawck offers over a single global hidden/always-hidden pair is the rest
/// of it: as many boundaries as you want, each named, each with its own glyph,
/// its own re-fold delay, and its own toggle.
///
/// ## One status item per cluster, deliberately
///
/// An earlier version paired each boundary with a small always-visible
/// companion, so a folded cluster still had a visible control. Measuring it on
/// a notched MacBook killed the idea: that menu bar was already full enough
/// that macOS was placing newly created status items off-screen outright, and a
/// space-saving feature that spends two slots per cluster to save one is
/// working against itself. A folded cluster is reopened from Dawck's own menu
/// bar icon, from Settings, or by clicking the strip the folded boundary leaves
/// behind.
final class MenuBarClusterManager {
    private let store: MenuBarClusterStore
    private var expanders: [UUID: NSStatusItem] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var collapseTimers: [UUID: Timer] = [:]

    /// Width of a cluster boundary while its cluster is open.
    private static let handleWidth: CGFloat = 24
    /// Used only when the item has no laid-out window to measure. Large enough
    /// to clear any menu bar; the system clamps it.
    private static let fallbackExpansion: CGFloat = 10_000

    init(store: MenuBarClusterStore) {
        self.store = store
        reconcile()

        store.$clusters
            .receive(on: RunLoop.main)
            .sink { [weak self] clusters in self?.reconcile(clusters) }
            .store(in: &cancellables)
    }

    deinit {
        collapseTimers.values.forEach { $0.invalidate() }
        expanders.values.forEach { NSStatusBar.system.removeStatusItem($0) }
    }

    // MARK: - Reconciliation

    private func reconcile(_ clusters: [MenuBarCluster]? = nil) {
        let clusters = clusters ?? store.clusters
        let ids = Set(clusters.map(\.id))

        for (id, item) in expanders where !ids.contains(id) {
            NSStatusBar.system.removeStatusItem(item)
            expanders.removeValue(forKey: id)
        }
        for id in collapseTimers.keys where !ids.contains(id) {
            collapseTimers[id]?.invalidate()
            collapseTimers.removeValue(forKey: id)
        }

        for cluster in clusters {
            if expanders[cluster.id] == nil {
                expanders[cluster.id] = makeItem(for: cluster)
            }
            apply(cluster)
            scheduleAutoCollapse(for: cluster)
        }
    }

    private func makeItem(for cluster: MenuBarCluster) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: Self.handleWidth)
        // A stable autosave name so macOS remembers where the user dragged this
        // particular boundary. Without it, every relaunch would drop the
        // boundaries back at their default position and scramble which icons
        // fall inside which cluster.
        item.autosaveName = "DawckCluster-\(cluster.id.uuidString)"
        item.button?.target = self
        item.button?.action = #selector(handleClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // The identifier carries the cluster id back to the click handler, so
        // the handler needs no parallel lookup table that could drift out of
        // sync with `expanders`.
        item.button?.identifier = NSUserInterfaceItemIdentifier(cluster.id.uuidString)
        return item
    }

    private func apply(_ cluster: MenuBarCluster) {
        guard let expander = expanders[cluster.id], let button = expander.button else { return }

        if cluster.isCollapsed {
            // The glyph would be centred hundreds of points to the left at this
            // width — off-screen — so it's cleared rather than left looking like
            // a stray icon. What remains is a clickable strip that reopens the
            // cluster.
            button.image = nil
            button.toolTip = "\(cluster.name) — folded. Click to reopen."
            applyExpansion(to: expander, attemptsRemaining: 5)
        } else {
            expander.length = Self.handleWidth
            button.image = symbolImage(cluster.symbol, named: cluster.name)
            button.toolTip = "\(cluster.name) — open. Click to fold. Command-drag icons to the left of this to put them in this cluster."
        }
    }

    private func symbolImage(_ name: String, named description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "chevron.left.2", accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    /// Grows the boundary far enough to push everything left of it off-screen.
    ///
    /// The distance is measured from the item's own right edge rather than
    /// using one big constant, so it stops around the screen edge instead of
    /// overshooting by thousands of points.
    ///
    /// `maxX` is the item's *right* edge, which stays anchored however long the
    /// item is — so re-applying this to an already-folded cluster is idempotent
    /// rather than compounding.
    ///
    /// At the moment a status item is first created its window isn't laid out
    /// and there is no frame to measure, so the sizing is retried on the next
    /// run-loop turn. The attempt count keeps an item that never gets a window
    /// from retrying forever.
    private func applyExpansion(to item: NSStatusItem, attemptsRemaining: Int) {
        if let rightEdge = item.button?.window?.frame.maxX, rightEdge > Self.handleWidth {
            let limit = NSScreen.main?.frame.width ?? Self.fallbackExpansion
            item.length = min(rightEdge, limit)
            return
        }

        guard attemptsRemaining > 0 else {
            item.length = Self.fallbackExpansion
            return
        }

        DispatchQueue.main.async { [weak self, weak item] in
            guard let self, let item else { return }
            // Re-checked rather than assumed: the cluster may have been reopened
            // in the turn between scheduling and running, and folding it now
            // would hide icons the user just asked to see.
            guard let id = self.expanders.first(where: { $0.value === item })?.key,
                  self.store.clusters.first(where: { $0.id == id })?.isCollapsed == true
            else { return }
            self.applyExpansion(to: item, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    // MARK: - Interaction

    @objc private func handleClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }

        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showMenu(for: id, from: sender)
            return
        }
        store.toggle(id)
    }

    /// Right-click gives the cluster's own controls without a trip to the
    /// settings window — the boundary is the thing the user is already pointing
    /// at when they want to rename or remove it.
    private func showMenu(for id: UUID, from button: NSStatusBarButton) {
        guard let cluster = store.clusters.first(where: { $0.id == id }) else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: cluster.name, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: cluster.isCollapsed ? "Reopen This Cluster" : "Fold This Cluster",
            action: #selector(menuToggle(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.representedObject = id
        menu.addItem(toggle)

        let revealAll = NSMenuItem(title: "Reopen All Clusters", action: #selector(menuRevealAll), keyEquivalent: "")
        revealAll.target = self
        menu.addItem(revealAll)

        let collapseAll = NSMenuItem(title: "Fold All Clusters", action: #selector(menuCollapseAll), keyEquivalent: "")
        collapseAll.target = self
        menu.addItem(collapseAll)

        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove This Cluster", action: #selector(menuRemove(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = id
        menu.addItem(remove)

        // Assigning the menu and clicking is the supported way to show a menu
        // from a status item; `popUpMenu` is deprecated and mispositions the
        // menu under a notch.
        if let item = expanders[id] {
            item.menu = menu
            button.performClick(nil)
            item.menu = nil
        }
    }

    @objc private func menuToggle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        store.toggle(id)
    }

    @objc private func menuRevealAll() { store.revealAll() }
    @objc private func menuCollapseAll() { store.collapseAll() }

    @objc private func menuRemove(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        guard let cluster = store.clusters.first(where: { $0.id == id }) else { return }
        store.remove(cluster)
    }

    // MARK: - Auto re-fold

    private func scheduleAutoCollapse(for cluster: MenuBarCluster) {
        collapseTimers[cluster.id]?.invalidate()
        collapseTimers.removeValue(forKey: cluster.id)

        guard !cluster.isCollapsed, cluster.autoCollapseDelay > 0 else { return }

        let timer = Timer(timeInterval: cluster.autoCollapseDelay, repeats: false) { [weak self] _ in
            self?.store.setCollapsed(true, for: cluster.id)
        }
        RunLoop.main.add(timer, forMode: .common)
        collapseTimers[cluster.id] = timer
    }
}
