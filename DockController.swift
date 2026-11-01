import AppKit
import SwiftUI
import Combine

/// What a controller needs from the rest of the app.
struct DockEnvironment {
    let store: SecondaryDockStore
    let themeStore: ThemeStore
    let openSettings: () -> Void
}

/// Which display a controller puts its dock on.
enum DockScreenTarget: Hashable {
    /// The display the dock is configured for.
    case dockDisplay
    /// A specific attached display, for docks shown on every screen.
    case display(Int)

    func resolve(for dock: SecondaryDock) -> NSScreen? {
        switch self {
        case .dockDisplay: return dock.display.resolve()
        case .display(let id): return NSScreen.screens.first { $0.displayID == id }
        }
    }
}

/// Runs one dock on one display: its window, what the window shows, when it
/// shows it, and what its tiles do.
///
/// Everything here is driven by events — a pointer movement, a workspace
/// notification, a store change. A controller with nothing happening to it
/// schedules no timers and costs no CPU.
final class DockController: NSObject, DockContentDelegate, NSPopoverDelegate {
    enum Presence { case shown, pill, hidden }

    let dockID: UUID
    let target: DockScreenTarget
    private(set) var dock: SecondaryDock
    private var theme: GlassTheme
    private let env: DockEnvironment
    let panel = SecondaryDockPanel()
    private(set) var content: DockContentView!

    // Rendering
    private var lastModel: DockRenderModel?
    private var refreshScheduled = false
    private var appearanceObservation: NSKeyValueObservation?

    // Visibility
    private(set) var presence: Presence = .hidden
    private var presenceGeneration = 0
    private var forcedHidden = false
    private var systemHidden = false
    private var revealed = false
    private var collapsedByIdle: Bool
    private var labelWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var revealWork: DispatchWorkItem?
    private var pointerWasInside = false
    private var hoverRect: NSRect = .zero
    private var isWindowObserved = false

    // Interaction state
    private var isEditing = false
    private var launching = Set<UUID>()
    private var trashFull = false
    private var popover: NSPopover?
    private var popoverTile: UUID?
    private var popoverHost: NSHostingController<AnyView>?

    // Per-controller services
    private var hotKeyID: UInt32?
    private var registeredHotKey: HotKeySpec?
    private var trashTimer: DispatchSourceTimer?
    private var liveIconTimer: DispatchSourceTimer?

    init(dock: SecondaryDock, target: DockScreenTarget, theme: GlassTheme, env: DockEnvironment) {
        self.dockID = dock.id
        self.target = target
        self.dock = dock
        self.theme = theme
        self.env = env
        self.collapsedByIdle = dock.collapseMode.isEnabled
        super.init()

        let model = buildModel()
        let metrics = DockContentView.makeMetrics(model: model, screenLength: screenLength())
        content = DockContentView(model: model, metrics: metrics)
        content.delegate = self
        panel.contentView = content
        lastModel = model
        configureLevel()
        applyWindow(metrics: metrics)

        DockPointerHub.shared.register(self) { [weak self] point in self?.pointerMoved(point) }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.requestRefresh() }
        }
        applyHotKey()
        updatePresence(animated: false)
        refreshServices()
        HoverLabelPanel.warmUp()
    }

    deinit { teardown() }

    func teardown() {
        DockPointerHub.shared.unregister(self)
        WidgetHub.shared.unsubscribe(self)
        WindowObserver.shared.unregister(self)
        if let hotKeyID { HotKeyCenter.shared.unregister(hotKeyID); self.hotKeyID = nil }
        trashTimer?.cancel(); trashTimer = nil
        liveIconTimer?.cancel(); liveIconTimer = nil
        collapseWork?.cancel(); revealWork?.cancel()
        dismissPopover()
        HoverLabelPanel.label.hide()
        appearanceObservation = nil
        panel.orderOut(nil)
    }

    // MARK: Model

    private func buildModel() -> DockRenderModel {
        let monitor = RunningAppsMonitor.shared
        let items = dock.visibleItems(liveDockItems: SystemDockReader.shared.items,
                                      runningBundleIDs: monitor.running,
                                      spaceBundleIDs: monitor.bundleIDsInCurrentSpace,
                                      isSpaceDataUsable: monitor.isSpaceDataUsable)
        let hub = WidgetHub.shared
        let tiles = items.map { item -> TileModel in
            var tile = TileModel(item: item)
            switch item.kind {
            case .file: if let id = item.bundleIdentifier { tile.isRunning = monitor.running.contains(id) }
            case .widget: tile.widget = hub.snapshot(for: item)
            case .trash: tile.isFull = trashFull
            default: break
            }
            tile.isLaunching = launching.contains(item.id)
            return tile
        }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return DockRenderModel(dock: dock, theme: theme, tiles: tiles, isEditing: isEditing,
                               systemIsDark: dark, isDerived: dock.contentMode != .manual)
    }

    func requestRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in self?.refreshNow() }
    }

    private func refreshNow() {
        refreshScheduled = false
        let model = buildModel()
        guard model != lastModel else { return }
        let previous = lastModel
        lastModel = model
        let metrics = DockContentView.makeMetrics(model: model, screenLength: screenLength())
        if metrics != content.metrics { applyWindow(metrics: metrics) }
        content.apply(model: model, metrics: metrics)
        updateHoverRect()

        for tile in model.tiles where tile.isLaunching != (previous?.tiles.first { $0.id == tile.id }?.isLaunching ?? false) {
            content.setLaunching(tile.id, tile.isLaunching)
        }
        if let id = popoverTile, let tile = model.tiles.first(where: { $0.id == id }) { refreshPopover(for: tile) }
        else if popoverTile != nil { dismissPopover() }
        if previous?.dock.items.map(\.id) != model.dock.items.map(\.id) || previous?.dock.contentMode != model.dock.contentMode {
            refreshServices()
        }
    }

    // MARK: Window

    private func screenLength() -> CGFloat? {
        guard dock.layoutMode == .stretch, let screen = target.resolve(for: dock) ?? NSScreen.main else { return nil }
        return dock.edge.isHorizontal ? screen.visibleFrame.width : screen.visibleFrame.height
    }

    private func configureLevel() {
        switch dock.windowLevel {
        case .floating:
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        case .desktop:
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
    }

    /// Places the window so the plate — not the window, which is larger to hold
    /// the shadow and magnified icons — sits where the dock is configured to.
    private func windowFrame(for metrics: DockMetrics) -> NSRect? {
        guard let screen = target.resolve(for: dock) ?? NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        let margin = CGFloat(dock.edgeMargin)
        let position = min(max(dock.alignment, 0), 1)
        let plate = metrics.plateRect
        var plateOrigin = CGPoint.zero
        switch dock.edge {
        case .bottom, .top:
            let travel = max(0, visible.width - plate.width - margin * 2)
            plateOrigin.x = visible.minX + margin + travel * position
            plateOrigin.y = dock.edge == .bottom ? visible.minY + margin : visible.maxY - margin - plate.height
        case .left, .right:
            let travel = max(0, visible.height - plate.height - margin * 2)
            plateOrigin.y = visible.maxY - margin - plate.height - travel * position
            plateOrigin.x = dock.edge == .left ? visible.minX + margin : visible.maxX - margin - plate.width
        }
        return NSRect(origin: CGPoint(x: plateOrigin.x - plate.minX, y: plateOrigin.y - plate.minY), size: metrics.windowSize)
    }

    private func applyWindow(metrics: DockMetrics) {
        guard let frame = windowFrame(for: metrics) else { return }
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        updateHoverRect()
    }

    /// Re-places the window after a display or Dock change.
    func reposition() {
        guard let content else { return }
        applyWindow(metrics: content.metrics)
    }

    // MARK: Updates from outside

    func update(dock newDock: SecondaryDock, theme newTheme: GlassTheme) {
        let collapseChanged = newDock.collapseMode != dock.collapseMode
        let levelChanged = newDock.windowLevel != dock.windowLevel
        dock = newDock
        theme = newTheme
        if collapseChanged {
            collapsedByIdle = newDock.collapseMode.isEnabled
            revealed = false
            collapseWork?.cancel(); collapseWork = nil
        }
        if levelChanged { configureLevel() }
        if newDock.hotkey == nil { forcedHidden = false }
        applyHotKey()
        requestRefresh()
        updatePresence(animated: true)
        refreshServices()
    }

    // MARK: Presence

    private func desiredPresence() -> Presence {
        if forcedHidden { return .hidden }
        if systemHidden && !revealed { return .hidden }
        if dock.collapseMode.isEnabled && collapsedByIdle && !revealed {
            return dock.collapseMode.collapsesToButton ? .pill : .hidden
        }
        return .shown
    }

    private func updatePresence(animated: Bool) {
        let new = desiredPresence()
        guard new != presence else { return }
        let old = presence
        presence = new
        presenceGeneration += 1
        switch new {
        case .shown, .pill:
            content.setCollapsed(new == .pill, animated: animated && old != .hidden)
            if old == .hidden { revealWindow(animated: animated) }
        case .hidden:
            content.setPointer(nil)
            pointerWasInside = false
            HoverLabelPanel.label.hide()
            dismissPopover()
            isEditing = false
            requestRefresh()
            concealWindow(animated: animated, generation: presenceGeneration)
        }
        updateHoverRect()
        refreshServices()
    }

    private func slideOffset() -> CGVector {
        let distance = content.metrics.plateBreadth + content.metrics.shadowMargin + CGFloat(dock.edgeMargin)
        switch dock.edge {
        case .bottom: return CGVector(dx: 0, dy: -distance)
        case .top: return CGVector(dx: 0, dy: distance)
        case .left: return CGVector(dx: -distance, dy: 0)
        case .right: return CGVector(dx: distance, dy: 0)
        }
    }

    private func revealWindow(animated: Bool) {
        panel.ignoresMouseEvents = true
        guard let final = windowFrame(for: content.metrics) else { return }
        let style = animated ? dock.appearAnimation : .none
        switch style {
        case .none:
            panel.setFrame(final, display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        case .fade, .pop:
            panel.setFrame(final, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }
            if style == .pop { content.playEntrance() }
        case .slide:
            let offset = slideOffset()
            panel.setFrame(final.offsetBy(dx: offset.dx, dy: offset.dy), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(final, display: false)
            }
        }
    }

    private func concealWindow(animated: Bool, generation: Int) {
        panel.ignoresMouseEvents = true
        guard panel.isVisible else { return }
        let style = dock.appearAnimation
        guard animated, style != .none else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        let current = panel.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
            if style == .slide {
                let offset = slideOffset()
                panel.animator().setFrame(current.offsetBy(dx: offset.dx, dy: offset.dy), display: false)
            }
        }, completionHandler: { [weak self] in
            guard let self, self.presenceGeneration == generation, self.presence == .hidden else { return }
            self.panel.orderOut(nil)
            if let frame = self.windowFrame(for: self.content.metrics) { self.panel.setFrame(frame, display: false) }
        })
    }

    // MARK: Pointer

    private func updateHoverRect() {
        guard let content, panel.screen != nil || panel.isVisible || true else { return }
        let interactive = content.screenRect(fromViewRect: content.interactiveRect.insetBy(dx: -24, dy: -24))
        var rect = interactive
        if let strip = edgeStrip() { rect = rect.union(strip) }
        hoverRect = rect
    }

    private func edgeStrip() -> NSRect? {
        guard let screen = target.resolve(for: dock) ?? NSScreen.main, let content else { return nil }
        let frame = screen.frame
        let plate = panel.frame.isEmpty ? .zero : content.screenRect(fromViewRect: content.metrics.plateRect)
        let depth = dock.revealZone.depth + 1
        let slack: CGFloat = 40
        switch dock.edge {
        case .bottom: return NSRect(x: plate.minX - slack, y: frame.minY, width: plate.width + slack * 2, height: depth)
        case .top: return NSRect(x: plate.minX - slack, y: frame.maxY - depth, width: plate.width + slack * 2, height: depth)
        case .left: return NSRect(x: frame.minX, y: plate.minY - slack, width: depth, height: plate.height + slack * 2)
        case .right: return NSRect(x: frame.maxX - depth, y: plate.minY - slack, width: depth, height: plate.height + slack * 2)
        }
    }

    private var allowsEdgeReveal: Bool {
        guard !forcedHidden else { return false }
        let faded = dock.collapseMode == .fadeOut && collapsedByIdle
        return faded || (systemHidden && dock.revealsAtEdgeWhenHidden)
    }

    private func pointerMoved(_ point: NSPoint) {
        if presence == .hidden {
            edgeCheck(point)
            return
        }
        let near = hoverRect.contains(point)
        if !near && !pointerWasInside {
            scheduleRetreat()
            return
        }
        pointerWasInside = near
        let local = content.convert(panel.convertPoint(fromScreen: point), from: nil)
        let interactive = near && content.interactiveRect.contains(local)
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
        content.setPointer(interactive ? local : nil)

        if presence == .pill, dock.collapseMode == .toButtonOnHover, interactive {
            expandFromPill()
            return
        }
        if near { cancelRetreat() } else { scheduleRetreat() }
    }

    private func edgeCheck(_ point: NSPoint) {
        guard allowsEdgeReveal, let strip = edgeStrip() else { cancelReveal(); return }
        if strip.contains(point) {
            guard revealWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.revealWork = nil
                guard let strip = self.edgeStrip(), strip.contains(NSEvent.mouseLocation) else { return }
                self.revealed = true
                self.collapsedByIdle = false
                self.updatePresence(animated: true)
            }
            revealWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        } else {
            cancelReveal()
        }
    }

    private func cancelReveal() { revealWork?.cancel(); revealWork = nil }

    private func expandFromPill() {
        collapsedByIdle = false
        updatePresence(animated: true)
    }

    /// When the pointer has been away long enough, a collapsing dock collapses
    /// and a dock that was summoned goes away again. One work item, scheduled
    /// when the pointer leaves and cancelled if it returns — never a poll.
    private func scheduleRetreat() {
        guard collapseWork == nil, presence == .shown, popover == nil, !isEditing,
              dock.collapseMode.isEnabled || revealed else { return }
        let delay = dock.collapseMode.isEnabled ? max(dock.collapseDelay, 0.1) : 0.6
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWork = nil
            guard !self.hoverRect.contains(NSEvent.mouseLocation), self.popover == nil, !self.isEditing else { return }
            if self.dock.collapseMode.isEnabled { self.collapsedByIdle = true }
            self.revealed = false
            self.updatePresence(animated: true)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelRetreat() { collapseWork?.cancel(); collapseWork = nil }

    // MARK: Services

    /// Starts exactly what the dock, in its current state, needs.
    private func refreshServices() {
        let items = lastModel?.tiles.map(\.item) ?? []
        let showing = presence == .shown

        WidgetHub.shared.subscribe(self, items: showing ? items : []) { [weak self] in self?.requestRefresh() }

        let wantsWindows = dock.hidesInFullscreen || dock.hidesOnWindowOverlap
        if wantsWindows != isWindowObserved {
            isWindowObserved = wantsWindows
            if wantsWindows {
                WindowObserver.shared.register(self) { [weak self] snapshot in self?.windowsChanged(snapshot) }
            } else {
                WindowObserver.shared.unregister(self)
                if systemHidden { systemHidden = false; revealed = false; updatePresence(animated: true) }
            }
        }

        let hasTrash = showing && items.contains { $0.kind == .trash }
        if hasTrash, trashTimer == nil {
            checkTrash()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.checkTrash() }
            timer.resume()
            trashTimer = timer
        } else if !hasTrash, let timer = trashTimer {
            timer.cancel(); trashTimer = nil
        }

        let hasLive = showing && items.contains { TileLayer.isLiveIcon($0) }
        if hasLive, liveIconTimer == nil {
            let now = Date().timeIntervalSinceReferenceDate
            let next = (now / 60).rounded(.down) * 60 + 60
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + (next - now), repeating: 60, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in self?.content.refreshLiveIcons() }
            timer.resume()
            liveIconTimer = timer
        } else if !hasLive, let timer = liveIconTimer {
            timer.cancel(); liveIconTimer = nil
        }
    }

    private func checkTrash() {
        let full = DockPrefs.bool("trash-full", default: false)
        if full != trashFull { trashFull = full; requestRefresh() }
    }

    private func windowsChanged(_ snapshot: WindowObserver.Snapshot) {
        guard let content else { return }
        var hidden = false
        let screen = target.resolve(for: dock) ?? NSScreen.main
        let isFullscreen = screen?.displayID.map { snapshot.fullscreenDisplays.contains($0) } ?? false
        if dock.hidesInFullscreen, isFullscreen { hidden = true }
        if dock.hidesOnWindowOverlap, !isFullscreen {
            let plate = content.screenRect(fromViewRect: content.metrics.plateRect).insetBy(dx: 2, dy: 2)
            hidden = hidden || snapshot.frames.contains { $0.intersects(plate) }
        }
        guard hidden != systemHidden else { return }
        systemHidden = hidden
        revealed = false
        updatePresence(animated: true)
    }

    // MARK: Hot key

    private func applyHotKey() {
        guard dock.hotkey != registeredHotKey else { return }
        if let hotKeyID { HotKeyCenter.shared.unregister(hotKeyID); self.hotKeyID = nil }
        registeredHotKey = dock.hotkey
        guard let spec = dock.hotkey, target == .dockDisplay || NSScreen.screens.first?.displayID.map({ target == .display($0) }) == true else { return }
        hotKeyID = HotKeyCenter.shared.register(spec) { [weak self] in self?.toggleFromHotKey() }
    }

    func toggleFromHotKey() {
        if presence == .shown && !revealed {
            forcedHidden = true
        } else if presence == .shown && revealed {
            revealed = false
            forcedHidden = true
        } else {
            forcedHidden = false
            revealed = true
            collapsedByIdle = false
        }
        updatePresence(animated: true)
    }

    // MARK: Tile clicks

    func dockContent(_ view: DockContentView, didClick tile: TileModel, rect: NSRect) {
        if isEditing { return }
        let item = tile.item
        switch item.kind {
        case .file:
            if item.isDirectory { present(tile, rect: rect) } else { open(tile) }
        case .action:
            runAction(item)
        case .tray, .group:
            present(tile, rect: rect)
        case .widget:
            widgetClick(tile, rect: rect)
        case .trash:
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
        case .separator:
            break
        }
    }

    func dockContentDidClickPill(_ view: DockContentView) { expandFromPill() }

    func dockContent(_ view: DockContentView, scrolled tile: TileModel, delta: CGFloat) {
        guard tile.item.kind == .widget, tile.item.widget == .volume else { return }
        WidgetHub.shared.adjustVolume(by: Double(max(-20, min(20, delta))) / 100)
    }

    func dockContent(_ view: DockContentView, remove id: UUID) {
        guard let tile = view.tileModel(id) else { return }
        if dock.contentMode == .liveDock, let bundleID = tile.item.bundleIdentifier {
            env.store.mutate(dockID) { if !$0.hiddenBundleIDs.contains(bundleID) { $0.hiddenBundleIDs.append(bundleID) } }
        } else if dock.contentMode == .manual {
            env.store.removeItem(id, from: dockID)
        }
    }

    /// The name bubble follows the hovered tile, but not frame by frame: a fast
    /// sweep crosses a dozen tiles, and moving a window for each would be work
    /// nobody sees. The bubble catches up once the pointer lingers for a moment.
    func dockContent(_ view: DockContentView, hover tile: TileModel?, screenRect: NSRect?) {
        labelWork?.cancel()
        #if BENCH
        if ProcessInfo.processInfo.environment["DAWCK_BENCH_NOLABEL"] != nil { return }
        #endif
        guard let tile, let rect = screenRect, tile.item.kind != .separator, popover == nil, !dock.showsLabels else {
            labelWork = nil
            HoverLabelPanel.label.hide()
            return
        }
        let name = tile.item.displayName
        // Only once the pointer has lingered: a fast sweep crosses a dozen tiles
        // and a label for each would be work nobody sees.
        HoverLabelPanel.label.hide()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            HoverLabelPanel.label.show(name, near: rect, edge: self.dock.edge, appearance: self.panel.effectiveAppearance)
        }
        labelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: Opening

    /// Clicking an app that is already running sends it the same "reopen"
    /// request the real Dock does, so an app with no windows open gets a new
    /// one instead of just being brought to the front with nothing to show.
    private func open(_ tile: TileModel) {
        let item = tile.item
        guard item.path.hasSuffix(".app") else {
            NSWorkspace.shared.open(item.url)
            return
        }
        let wasRunning = tile.isRunning
        if !wasRunning, dock.bouncesOnLaunch {
            launching.insert(item.id)
            requestRefresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                if self?.launching.remove(item.id) != nil { self?.requestRefresh() }
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.launching.remove(item.id) != nil { self.requestRefresh() }
                if let error { self.toast("Couldn't open \(item.displayName): \(error.localizedDescription)", near: item.id) }
            }
        }
    }

    private func runAction(_ item: DockItem) {
        guard item.isTrusted else {
            let alert = NSAlert()
            alert.messageText = "Run this action?"
            alert.informativeText = "This action came from an imported profile and hasn't been approved yet.\n\n\(item.actionType.label): \(String(item.actionPayload.prefix(300)))"
            alert.addButton(withTitle: "Run and Trust")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            env.store.mutate(dockID) { dock in
                if let index = dock.items.firstIndex(where: { $0.id == item.id }) { dock.items[index].isTrusted = true }
            }
            var trusted = item
            trusted.isTrusted = true
            runAction(trusted)
            return
        }
        ActionRunner.run(item) { [weak self] failure in
            guard let failure else { return }
            self?.toast(failure.errorDescription ?? "That action failed.", near: item.id)
        }
    }

    private func widgetClick(_ tile: TileModel, rect: NSRect) {
        let hub = WidgetHub.shared
        let options = tile.item.widgetOptions
        switch tile.item.widget {
        case .timer: hub.toggleStopwatch()
        case .countdown: hub.toggleCountdown(minutes: options.countdownMinutes)
        case .caffeine: hub.toggleCaffeine()
        case .keyboardLayout: hub.cycleKeyboardLayout()
        case .nowPlaying: hub.playPause()
        case .volume: hub.toggleMute()
        case .audioOutput: showAudioMenu(near: rect)
        case .calendar: present(tile, rect: rect)
        case .ip:
            if let text = hub.copyIPToPasteboard(mode: options.ipMode) { toast("Copied \(text)", near: tile.id) }
        case .date: openApplication("/System/Applications/Calendar.app")
        case .cpu, .memory, .gpu, .network, .disk, .thermal: openApplication("/System/Applications/Utilities/Activity Monitor.app")
        case .battery, .peripherals:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
        case .weather: openApplication("/System/Applications/Weather.app")
        case .clock, .analogClock, .worldClock: openApplication("/System/Applications/Clock.app")
        }
    }

    private func openApplication(_ path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }

    private func showAudioMenu(near rect: NSRect) {
        let devices = AudioDevices.shared
        devices.refresh()
        let menu = NSMenu()
        menu.addHeader("Sound Output")
        for device in devices.outputs {
            menu.add(device.name, state: device.isDefault ? .on : .off) { devices.select(device) }
        }
        let local = content.convert(panel.convertFromScreen(rect), from: nil)
        menu.popUp(positioning: nil, at: NSPoint(x: local.midX, y: local.midY), in: content)
    }

    private func toast(_ text: String, near id: UUID?) {
        let rect = id.flatMap { content.visualRect(of: $0) }.map { content.screenRect(fromViewRect: $0) }
            ?? content.screenRect(fromViewRect: content.metrics.plateRect)
        HoverLabelPanel.toast.show(text, near: rect, edge: dock.edge, appearance: panel.effectiveAppearance, lifetime: 4)
    }

    // MARK: Popovers

    private func popoverContent(for tile: TileModel) -> AnyView {
        let item = tile.item
        let id = dockID
        let store = env.store
        switch item.kind {
        case .tray:
            return AnyView(TrayPopoverView(item: item) { updated in store.replaceItem(updated, in: id) })
        case .group:
            return AnyView(GroupPopoverView(paths: item.memberPaths) { url in NSWorkspace.shared.open(url) })
        case .widget:
            return AnyView(CalendarPopoverView())
        default:
            return AnyView(FolderBrowserView(folderURL: item.url, options: item.folderOptions, onOptionsChange: { options in
                var updated = item
                updated.folderOptions = options
                store.replaceItem(updated, in: id)
            }, onOpen: { url in NSWorkspace.shared.open(url) }))
        }
    }

    private func present(_ tile: TileModel, rect: NSRect) {
        if popoverTile == tile.id { dismissPopover(); return }
        dismissPopover()
        HoverLabelPanel.label.hide()
        let host = NSHostingController(rootView: popoverContent(for: tile))
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.contentViewController = host
        pop.show(relativeTo: rect, of: content, preferredEdge: dock.edge.popoverEdge)
        popover = pop
        popoverHost = host
        popoverTile = tile.id
        cancelRetreat()
    }

    private func refreshPopover(for tile: TileModel) {
        // Trays and groups change while open (a file removed); folders keep
        // their own browsing state and are left alone.
        guard tile.item.kind == .tray || tile.item.kind == .group else { return }
        popoverHost?.rootView = popoverContent(for: tile)
    }

    func dismissPopover() {
        popover?.close()
        popover = nil
        popoverHost = nil
        popoverTile = nil
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        popoverHost = nil
        popoverTile = nil
        scheduleRetreat()
    }

    // MARK: Drops

    func dockContent(_ view: DockContentView, canAccept intent: DropIntent) -> Bool { true }

    func dockContent(_ view: DockContentView, perform intent: DropIntent, urls: [URL], copy: Bool) -> Bool {
        switch intent {
        case .open(let id):
            guard let tile = view.tileModel(id) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: tile.item.url, configuration: configuration) { [weak self] _, error in
                guard let error else { return }
                DispatchQueue.main.async { self?.toast("Couldn't open that with \(tile.item.displayName): \(error.localizedDescription)", near: id) }
            }
            return true
        case .moveInto(let id):
            guard let tile = view.tileModel(id) else { return false }
            return move(urls, into: tile.item.url, copy: copy, near: id)
        case .stash(let id):
            guard let tile = view.tileModel(id) else { return false }
            var updated = tile.item
            for url in urls where !updated.memberPaths.contains(url.path) && updated.memberPaths.count < 500 {
                if updated.kind == .group, !url.path.hasSuffix(".app") { continue }
                updated.memberPaths.append(url.path)
            }
            env.store.replaceItem(updated, in: dockID)
            return true
        case .trash:
            NSWorkspace.shared.recycle(urls) { [weak self] _, error in
                guard let error else { return }
                DispatchQueue.main.async { self?.toast("Couldn't move that to the Trash: \(error.localizedDescription)", near: nil) }
            }
            return true
        case .pin(let index):
            let items = urls.map { DockItem(path: $0.path) }
            env.store.insertItems(items, at: index, in: dockID)
            return true
        case .reorder(let id, let index):
            env.store.moveItem(id: id, toInsertionIndex: index, in: dockID)
            return true
        }
    }

    private func move(_ urls: [URL], into folder: URL, copy: Bool, near id: UUID) -> Bool {
        let manager = FileManager.default
        var moved = false
        for url in urls {
            let standardized = url.standardizedFileURL
            if standardized == folder.standardizedFileURL || folder.standardizedFileURL.path.hasPrefix(standardized.path + "/") { continue }
            if standardized.deletingLastPathComponent() == folder.standardizedFileURL { continue }
            var destination = folder.appendingPathComponent(url.lastPathComponent)
            var counter = 2
            while manager.fileExists(atPath: destination.path) {
                let base = url.deletingPathExtension().lastPathComponent
                let name = url.pathExtension.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(url.pathExtension)"
                destination = folder.appendingPathComponent(name)
                counter += 1
            }
            do {
                if copy { try manager.copyItem(at: url, to: destination) } else { try manager.moveItem(at: url, to: destination) }
                moved = true
            } catch {
                toast("Couldn't \(copy ? "copy" : "move") \(url.lastPathComponent): \(error.localizedDescription)", near: id)
            }
        }
        return moved
    }

    // MARK: Menus

    private var canEditTiles: Bool { dock.contentMode == .manual && (isEditing || !dock.isLocked) }

    func dockContent(_ view: DockContentView, menuFor tile: TileModel?, rect: NSRect) -> NSMenu? {
        let menu = NSMenu()
        if let tile {
            tileMenu(menu, for: tile, rect: rect)
            if !menu.items.isEmpty { menu.addItem(.separator()) }
        }
        plateMenu(menu)
        return menu
    }

    private func tileMenu(_ menu: NSMenu, for tile: TileModel, rect: NSRect) {
        let item = tile.item
        menu.addHeader(item.displayName)
        switch item.kind {
        case .file:
            menu.add(item.isDirectory ? "Open Folder" : "Open") { [weak self] in
                if item.isDirectory { NSWorkspace.shared.open(item.url) } else { self?.open(tile) }
            }
            if tile.isRunning, let bundleID = item.bundleIdentifier {
                menu.add("Quit") { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() } }
                menu.add("Hide") { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.hide() } }
            }
            menu.add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            if item.isDirectory {
                let options = menu.addSubmenu("Folder View", symbol: "square.grid.2x2")
                for layout in FolderLayout.allCases {
                    options.add(layout.label, symbol: layout.symbol, state: item.folderOptions.layout == layout ? .on : .off) { [weak self] in
                        self?.setFolderOptions(item) { $0.layout = layout }
                    }
                }
                options.addItem(.separator())
                for sort in FolderSort.allCases {
                    options.add("Sort by \(sort.label)", state: item.folderOptions.sort == sort ? .on : .off) { [weak self] in
                        self?.setFolderOptions(item) { $0.sort = sort }
                    }
                }
                options.addItem(.separator())
                options.add("Show Hidden Files", state: item.folderOptions.showsHidden ? .on : .off) { [weak self] in
                    self?.setFolderOptions(item) { $0.showsHidden.toggle() }
                }
                options.add("Show Previews", state: item.folderOptions.showsPreviews ? .on : .off) { [weak self] in
                    self?.setFolderOptions(item) { $0.showsPreviews.toggle() }
                }
            }
        case .action:
            menu.add("Run") { [weak self] in self?.runAction(item) }
        case .tray:
            menu.add("Open Tray") { [weak self] in self?.present(tile, rect: rect) }
            menu.add("Empty Tray", enabled: !item.memberPaths.isEmpty) { [weak self] in
                var updated = item; updated.memberPaths.removeAll()
                self?.env.store.replaceItem(updated, in: self?.dockID ?? UUID())
            }
        case .group:
            menu.add("Show Apps") { [weak self] in self?.present(tile, rect: rect) }
            menu.add("Open All") { item.memberPaths.forEach { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) } }
        case .trash:
            menu.add("Open Trash") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")) }
            menu.add("Empty Trash…", enabled: tile.isFull) { [weak self] in self?.confirmEmptyTrash() }
        case .widget:
            widgetMenu(menu, for: tile, rect: rect)
        case .separator:
            break
        }
        if canEditTiles, item.kind != .separator || true {
            menu.addItem(.separator())
            menu.add("Remove from \(dock.name)") { [weak self] in self?.env.store.removeItem(item.id, from: self?.dockID ?? UUID()) }
        } else if dock.contentMode == .liveDock, let bundleID = item.bundleIdentifier {
            menu.addItem(.separator())
            menu.add("Hide from This Mirror") { [weak self] in
                self?.env.store.mutate(self?.dockID ?? UUID()) { if !$0.hiddenBundleIDs.contains(bundleID) { $0.hiddenBundleIDs.append(bundleID) } }
            }
        }
    }

    private func widgetMenu(_ menu: NSMenu, for tile: TileModel, rect: NSRect) {
        let hub = WidgetHub.shared
        let options = tile.item.widgetOptions
        switch tile.item.widget {
        case .timer:
            menu.add(tile.widget?.symbol == "pause.fill" ? "Pause" : "Start") { hub.toggleStopwatch() }
            menu.add("Reset") { hub.resetStopwatch() }
        case .countdown:
            menu.add(tile.widget?.symbol == "pause.fill" ? "Pause" : "Start") { hub.toggleCountdown(minutes: options.countdownMinutes) }
            menu.add("Reset") { hub.resetCountdown() }
        case .caffeine:
            menu.add(hub.isCaffeinated ? "Allow Sleep" : "Keep Awake") { hub.toggleCaffeine() }
        case .nowPlaying:
            menu.add("Play / Pause") { hub.playPause() }
            menu.add("Next Track") { hub.nowPlayingCommand("next track") }
            menu.add("Previous Track") { hub.nowPlayingCommand("previous track") }
        case .volume:
            menu.add("Mute / Unmute") { hub.toggleMute() }
        case .audioOutput:
            AudioDevices.shared.refresh()
            for device in AudioDevices.shared.outputs {
                menu.add(device.name, state: device.isDefault ? .on : .off) { AudioDevices.shared.select(device) }
            }
        case .keyboardLayout:
            menu.add("Next Input Source") { hub.cycleKeyboardLayout() }
        case .ip:
            menu.add("Copy Address") { [weak self] in
                if let text = hub.copyIPToPasteboard(mode: options.ipMode) { self?.toast("Copied \(text)", near: tile.id) }
            }
        case .calendar:
            menu.add("Show Month") { [weak self] in self?.present(tile, rect: rect) }
            menu.add("Open Calendar") { [weak self] in self?.openApplication("/System/Applications/Calendar.app") }
        case .cpu, .memory, .gpu, .network, .disk, .thermal:
            menu.add("Open Activity Monitor") { [weak self] in self?.openApplication("/System/Applications/Utilities/Activity Monitor.app") }
        default:
            break
        }
    }

    private func setFolderOptions(_ item: DockItem, _ change: (inout FolderOptions) -> Void) {
        var updated = item
        change(&updated.folderOptions)
        env.store.replaceItem(updated, in: dockID)
    }

    private func confirmEmptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "Items in the Trash will be permanently deleted. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSAppleScript(source: "tell application \"Finder\" to empty the trash")?.executeAndReturnError(nil)
    }

    private func plateMenu(_ menu: NSMenu) {
        let id = dockID
        let store = env.store
        if dock.contentMode == .manual {
            menu.add(isEditing ? "Done Editing" : "Edit Dock", symbol: isEditing ? "checkmark.circle" : "pencil") { [weak self] in
                guard let self else { return }
                self.isEditing.toggle()
                if self.isEditing { self.cancelRetreat() }
                self.requestRefresh()
            }
            if canEditTiles { addMenu(menu) }
            menu.add(dock.isLocked ? "Unlock Dock" : "Lock Dock", symbol: dock.isLocked ? "lock.open" : "lock") {
                store.mutate(id) { $0.isLocked.toggle() }
            }
        }
        menu.add("Hide Dock", symbol: "eye.slash") { [weak self] in
            self?.forcedHidden = true
            self?.updatePresence(animated: true)
        }
        menu.add("Dock Settings…", symbol: "gearshape") { [weak self] in self?.env.openSettings() }
    }

    private func addMenu(_ menu: NSMenu) {
        let id = dockID
        let store = env.store
        let add = menu.addSubmenu("Add", symbol: "plus")
        add.add("App or Folder…", symbol: "folder.badge.plus") { [weak self] in self?.chooseItems() }
        add.add("Spacer", symbol: "space") { store.appendItem(DockItem(kind: .separator), to: id) }
        add.add("File Tray", symbol: "tray") { store.appendItem(DockItem(kind: .tray), to: id) }
        add.add("Trash", symbol: "trash") {
            if !(store.docks.first { $0.id == id }?.items.contains { $0.kind == .trash } ?? false) { store.appendItem(DockItem(kind: .trash), to: id) }
        }
        add.add("App Group", symbol: "square.stack.3d.up") { store.appendItem(DockItem(kind: .group), to: id) }
        let widgets = add.addSubmenu("Widget", symbol: "gauge.with.dots.needle.33percent")
        for category in DockWidgetKind.Category.allCases {
            let section = widgets.addSubmenu(category.rawValue)
            for kind in DockWidgetKind.allCases where kind.category == category {
                section.add(kind.label, symbol: kind.symbol) {
                    var item = DockItem(kind: .widget)
                    item.widget = kind
                    store.appendItem(item, to: id)
                }
            }
        }
    }

    private func chooseItems() {
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = true
        open.allowsMultipleSelection = true
        open.directoryURL = URL(fileURLWithPath: "/Applications")
        open.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        open.begin { [weak self] response in
            guard let self, response == .OK else { return }
            self.env.store.insertItems(open.urls.map { DockItem(path: $0.path) }, at: self.dock.items.count, in: self.dockID)
        }
    }

    // MARK: Benchmark

    #if BENCH
    /// Brings a hidden dock into view the way the pointer reaching the edge does.
    func benchReveal() {
        revealed = true
        collapsedByIdle = false
        updatePresence(animated: true)
    }

    /// Drives the pointer along the dock without touching the real cursor, through
    /// the same path real mouse events take (hit regions, hover label, easing).
    func benchPointer(_ fraction: Double?) {
        guard let fraction else { pointerMoved(NSPoint(x: -10_000, y: -10_000)); return }
        let m = content.metrics
        let local = m.point(m: CGFloat(fraction) * m.plateLength, c: m.plateBreadth / 2)
        pointerMoved(panel.convertPoint(toScreen: content.convert(local, to: nil)))
    }
    #endif
}

extension SecondaryDock {
    /// Whether launching an app from this dock bounces its tile.
    var bouncesOnLaunch: Bool { true }
}

extension NSMenu {
    @discardableResult
    func addSubmenu(_ title: String, symbol: String? = nil) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        addItem(item)
        return submenu
    }
}
