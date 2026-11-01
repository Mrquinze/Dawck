import SwiftUI
import AppKit

/// The first-run tour and the "what's new" page, in one window: new users get
/// the tour, people upgrading get what changed, and anyone can open it again
/// from Settings → General or the menu bar.
struct WelcomeView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case new = "What's New"
        case start = "Getting Started"
        var id: String { rawValue }
    }

    let version: String
    let isUpgrade: Bool
    @State var tab: Tab
    let createStarterDock: () -> Void
    let openSettings: (ContentView.Pane) -> Void
    let close: () -> Void

    @AppStorage(WelcomeWindowController.showOnUpdateKey) private var showsOnUpdate = true
    @State private var createdStarter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 12) {
                    switch tab {
                    case .new: ForEach(Self.features) { FeatureRow(feature: $0) }
                    case .start: gettingStarted
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            }
            .defaultScrollAnchor(.top)
            .id(tab)

            footer
        }
        .frame(width: 640, height: 700)
        .background { AmbientBackdrop() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            Text(isUpgrade ? "Dawck \(version)" : "Welcome to Dawck")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(isUpgrade ? "A faster, glassier Dawck, with a lot more in it."
                           : "Extra docks, widgets and menu bar tidying for your Mac.")
                .font(.title3).foregroundStyle(.secondary)
        }
        .padding(.top, 30).padding(.bottom, 18)
    }

    private var gettingStarted: some View {
        VStack(spacing: 12) {
            StepCard(number: 1, title: "Make a dock", text: "A dock is a floating bar of apps, folders, widgets and actions that sits on any edge of any display.",
                     button: createdStarter ? "Created ✓" : "Create a Starter Dock") {
                createStarterDock()
                createdStarter = true
            }
            StepCard(number: 2, title: "Fill it", text: "Drag apps onto it from Finder. Right-click the dock for Edit Dock, Add, Lock and Hide. Drop files on an app to open them with it, or on a folder to move them in.",
                     button: "Open Docks") { openSettings(.docks) }
            StepCard(number: 3, title: "Choose a look", text: "Pick a design and a palette, or switch to Apple's own Liquid Glass. Every slider updates your docks live.",
                     button: "Open Theme") { openSettings(.theme) }
            StepCard(number: 4, title: "Add widgets", text: "Clocks, battery, network speed, weather, now playing, a stopwatch and more — each one only measures while it is on screen.",
                     button: "Browse Widgets") { openSettings(.widgets) }
            StepCard(number: 5, title: "Tidy the rest", text: "Hide menu bar clutter, restyle the system Dock and set hot corners from the other sidebar sections.",
                     button: "Open System Dock") { openSettings(.mainDock) }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Show this after updates", isOn: $showsOnUpdate).toggleStyle(.checkbox)
            Spacer()
            Button("Open Settings") { openSettings(.docks); close() }.glassButtonStyle()
            Button("Done", action: close).glassButtonStyle(prominent: true).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
    }

    // MARK: Content

    struct Feature: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let text: String
    }

    static let features: [Feature] = [
        .init(symbol: "bolt.fill", title: "Smooth as glass",
              text: "Docks are drawn by a new renderer. Magnifying, appearing, hiding and glowing now hold a steady 60 fps, and hovering costs a fraction of what it did."),
        .init(symbol: "rectangle.dashed", title: "No more box around your docks",
              text: "The faint rectangular layer behind each dock is gone: the blur and shadow now follow the dock's own shape exactly."),
        .init(symbol: "drop.halffull", title: "Liquid Glass",
              text: "Choose Apple's own Liquid Glass — clear or frosted — for any dock, or let Dawck's custom glass follow the new macOS 27 clear↔opaque slider. The settings window is glass too."),
        .init(symbol: "paintpalette", title: "Designs & palettes",
              text: "Twenty palettes (including Goorgle's) and a gallery of designs, from crystal pills to flat paper. Edit up to five colours and the angle yourself."),
        .init(symbol: "square.grid.2x2", title: "Thirteen new widgets",
              text: "Analogue and world clocks, a month calendar, GPU load, network speed, IP address, device batteries, thermal state, volume, keyboard layout, keep-awake, a countdown and weather."),
        .init(symbol: "eye.slash", title: "Docks that step aside",
              text: "Hide a dock while an app is full screen or a window covers it, and bring it back by pushing the pointer to the screen edge. Give each dock its own show/hide shortcut."),
        .init(symbol: "lock", title: "Edit mode & locking",
              text: "Lock a dock so a stray drag can't change it, then right-click → Edit Dock to rearrange, add and remove with the familiar minus badges."),
        .init(symbol: "tray.and.arrow.down", title: "Smarter drops",
              text: "Drop files on an app to open them with it, on a folder to move them in (hold ⌥ to copy), on a tray to stash them, or on the Trash to throw them away."),
        .init(symbol: "folder", title: "Better folders",
              text: "Folders open as a grid, list or fan, sorted your way, with hidden files on request and real previews of pictures, PDFs and documents."),
        .init(symbol: "calendar", title: "Live icons & friendlier clicks",
              text: "Calendar and Clock tiles show today's date and the time. Clicking an app with no windows opens a new one, and launching apps bounce."),
        .init(symbol: "display.2", title: "Every display",
              text: "Show one dock on all your screens, or mirror your system Dock on a second display and hide the apps you don't want there."),
        .init(symbol: "leaf", title: "Lighter on your Mac",
              text: "Everything is event-driven: nothing polls while you aren't looking at it, widgets only measure while they are visible, and the settings window is built only when you open it."),
        .init(symbol: "lock.shield", title: "Safer imports",
              text: "Profiles from other people arrive with their actions switched off until you approve them, and every imported value is checked and size-limited."),
    ]
}

private struct FeatureRow: View {
    let feature: WelcomeView.Feature

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: feature.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title).font(.headline)
                Text(feature.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 18)
    }
}

private struct StepCard: View {
    let number: Int
    let title: String
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.22), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(button, action: action).glassButtonStyle()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 18)
    }
}

/// Shows the welcome window the first time a version runs, and on request.
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    static let seenKey = "welcome.lastSeenVersion"
    static let showOnUpdateKey = "welcome.showOnUpdate"

    private var window: NSWindow?
    private var dockStore: SecondaryDockStore?

    private override init() { super.init() }

    var isShowing: Bool { window?.isVisible == true }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "3.0"
    }

    func configure(dockStore: SecondaryDockStore) { self.dockStore = dockStore }

    /// Shown once per version: the tour for a brand-new install, "what's new"
    /// for an upgrade, and nothing at all if the user turned it off.
    func showIfNeeded() {
        let defaults = UserDefaults.standard
        let seen = defaults.string(forKey: Self.seenKey)
        guard seen != version else { return }
        let hadDocks = !(dockStore?.docks.isEmpty ?? true)
        defaults.set(version, forKey: Self.seenKey)
        let wantsUpdates = defaults.object(forKey: Self.showOnUpdateKey) as? Bool ?? true
        if seen != nil, !wantsUpdates { return }
        show(force: false, upgrade: seen != nil || hadDocks)
    }

    func show(force: Bool, upgrade: Bool? = nil) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let isUpgrade = upgrade ?? (UserDefaults.standard.string(forKey: Self.seenKey) != nil && !(dockStore?.docks.isEmpty ?? true))
        let view = WelcomeView(version: version, isUpgrade: isUpgrade, tab: isUpgrade ? .new : .start,
                               createStarterDock: { [weak self] in self?.dockStore?.addStarterDock() },
                               openSettings: { pane in SettingsWindowController.shared.show(pane: pane) },
                               close: { [weak self] in self?.window?.close() })
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 640, height: 700))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.window?.contentViewController = nil
            self?.window = nil
        }
    }
}
