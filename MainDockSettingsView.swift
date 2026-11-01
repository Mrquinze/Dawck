import SwiftUI

/// Settings for the *real* macOS Dock, written straight into `com.apple.dock`.
struct MainDockSettingsView: View {
    @EnvironmentObject private var dockStore: SecondaryDockStore
    @EnvironmentObject private var themeStore: ThemeStore

    @State private var settings = DockDefaultsManager.fallbackSettings
    @State private var isDirty = false
    @State private var lastActionMessage: String?
    @State private var isWorking = false
    @State private var accentColor = SystemAccentColor.current()
    @State private var isAccentWorking = false
    @State private var isReplacementActive = SystemDockReplacement.isActive
    @State private var isReplacementWorking = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Replace the System Dock") {
                    Text("The real Dock can't be reskinned \u{2014} no theming, no glass, not by this app or any other, since there's no public way to reach into how it draws itself. What every Dock replacement utility actually does, this one included, is hide the real one and put a fully themeable Dawck dock in its place, mirroring the same apps. \u{201C}Extra dock\u{201D} customization and \u{201C}system dock\u{201D} customization become the same thing once the real one is out of the way.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if isReplacementActive {
                        Label("The real Dock is hidden. A Dawck dock is standing in for it.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Bring Back the Real Dock") { disableReplacement() }
                            .disabled(isReplacementWorking)
                    } else {
                        Button("Set Up Full Replacement") { enableReplacement() }
                            .disabled(isReplacementWorking)
                    }

                    Text("This is a standing change to your real Dock, in effect whether or not Dawck is running. The undo above works from here at any time; without Dawck installed at all, System Settings \u{2192} Desktop & Dock \u{2192} turning off \u{201C}Automatically hide and show the Dock\u{201D} reverses it just as completely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Presets") {
                    Text("The real Dock has no colour or material of its own to theme — com.apple.dock carries no such key, which is exactly why Dawck's own floating docks exist as a separate, fully themeable thing. These presets bundle its actual tunable settings instead: size, position, motion, density.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(SystemDockPreset.all) { preset in
                                Button {
                                    apply(preset)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(preset.name, systemImage: preset.symbol)
                                            .font(.headline)
                                        Text(preset.blurb)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .frame(width: 168, alignment: .leading)
                                    .padding(10)
                                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Text("Each one restarts the Dock, the same as Apply below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Accent Colour") {
                    Picker("System Accent Colour", selection: $accentColor) {
                        ForEach(SystemAccentColor.allCases) { color in
                            Label {
                                Text(color.label)
                            } icon: {
                                Circle().fill(Color(nsColor: color.swatch)).frame(width: 12, height: 12)
                            }
                            .tag(color)
                        }
                    }
                    Text("The closest thing to a real colour lever near the Dock — it tints selection highlights and badges there, but it isn't Dock-scoped. This changes your whole Mac's accent colour everywhere, immediately, not just the Dock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Apply Accent Colour") { applyAccentColor() }
                        .disabled(isAccentWorking || accentColor == SystemAccentColor.current())
                }

                Section("Appearance") {
                    LabeledContent("Icon Size") {
                        ValueSlider(value: binding(\.tileSize), range: 16...128, step: 1, format: "%.0f pt")
                    }
                    Toggle("Magnify on Hover", isOn: binding(\.magnificationEnabled))
                    if settings.magnificationEnabled {
                        LabeledContent("Magnified Size") {
                            ValueSlider(value: binding(\.magnifiedTileSize), range: 16...128, step: 1, format: "%.0f pt")
                        }
                    }
                    Picker("Position on Screen", selection: binding(\.position)) {
                        ForEach(DockPosition.allCases) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    Picker("Minimize Effect", selection: binding(\.minimizeEffect)) {
                        ForEach(DockMinimizeEffect.allCases) { effect in
                            Text(effect.label).tag(effect)
                        }
                    }
                    Button("Make My Extra Docks the Same Size") { matchExtraDocks() }
                        .help("Copies this icon size and magnification to every Dawck dock, so they sit comfortably beside the system Dock.")
                    Toggle("Minimize Windows into App Icon", isOn: binding(\.minimizeToApplication))
                    Toggle("Animate Opening Applications", isOn: binding(\.launchAnimation))
                }

                Section("Behavior") {
                    Toggle("Automatically Hide and Show Dock", isOn: binding(\.autohide))
                    if settings.autohide {
                        LabeledContent("Show Delay") {
                            ValueSlider(value: binding(\.autohideDelay), range: 0...2, step: 0.05, format: "%.2f s")
                        }
                        LabeledContent("Animation Speed") {
                            ValueSlider(value: binding(\.autohideAnimationDuration), range: 0...1, step: 0.05, format: "%.2f s")
                        }
                    }
                    Toggle("Show Recent Applications", isOn: binding(\.showRecentApplications))
                    if settings.showRecentApplications {
                        Stepper("Recent Applications Shown: \(settings.recentAppsCount)", value: binding(\.recentAppsCount), in: 1...12)
                    }
                    Toggle("Highlight Stack Items as the Pointer Passes", isOn: binding(\.highlightsStacksOnHover))
                    Toggle("Show Only Open Applications", isOn: binding(\.showOnlyOpenApplications))
                    Toggle("Show Indicators for Open Applications", isOn: binding(\.showProcessIndicators))
                    Toggle("Single App Mode (click hides others)", isOn: binding(\.singleAppMode))
                }

                Section("Placement") {
                    Picker("Pin to Edge", selection: binding(\.pinning)) {
                        ForEach(DockPinning.allCases) { pinning in
                            Text(pinning.label).tag(pinning)
                        }
                    }
                    Text("Only visible once the Dock is narrower than the edge it sits on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Windows & Spaces") {
                    Toggle("Bounce Icons on Notification", isOn: binding(\.bouncesOnNotification))
                    Toggle("Dim Icons of Hidden Apps", isOn: binding(\.dimsHiddenApps))
                    Toggle("Group Windows by App in Mission Control", isOn: binding(\.groupsWindowsByApp))
                    Toggle("Rearrange Spaces by Most Recent Use", isOn: binding(\.rearrangesSpacesByUse))
                    Toggle("Scroll Up on an Icon to Show Its Windows", isOn: binding(\.scrollToOpen))
                    Toggle("Spring-Load Every Dock Item", isOn: binding(\.springLoadsAllItems))
                    Toggle("Show App Switcher on All Displays", isOn: binding(\.appSwitcherOnAllDisplays))
                }

                Section("Lock the Dock") {
                    Toggle("Lock Size", isOn: binding(\.sizeLocked))
                    Toggle("Lock Position", isOn: binding(\.positionLocked))
                    Toggle("Lock Contents", isOn: binding(\.contentsLocked))
                    if settings.contentsLocked {
                        Label("While contents are locked, macOS refuses changes to Dock items — including the ones made on the Contents tab.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let lastActionMessage {
                    Text(lastActionMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reload from Dock") {
                    loadSettings(completionMessage: "Reloaded settings from the Dock.")
                }
                Button("Apply & Restart Dock") { applySettings() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty || isWorking)
            }
            .padding()
        }
        .onAppear { loadSettings() }
    }

    private func matchExtraDocks() {
        for dock in dockStore.docks {
            dockStore.mutate(dock.id) {
                $0.tileSize = settings.tileSize
                $0.magnificationEnabled = settings.magnificationEnabled
                $0.magnifiedTileSize = max(settings.magnifiedTileSize, settings.tileSize)
            }
        }
        lastActionMessage = "Matched \(dockStore.docks.count) extra dock\(dockStore.docks.count == 1 ? "" : "s") to the system Dock's size."
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<DockDefaultsManager.Settings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
                isDirty = true
            }
        )
    }

    /// `DockDefaultsManager` shells out to `/usr/bin/defaults` and blocks on
    /// `waitUntilExit`. Running that synchronously on the main thread — e.g.
    /// from a `@State` initializer during SwiftUI's initial view construction —
    /// can trip an AttributeGraph "setting value during update" crash if the
    /// nested run-loop pump lands mid-render. Every call here goes through a
    /// background queue instead.
    private func loadSettings(completionMessage: String? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = DockDefaultsManager.loadCurrentSettings()
            DispatchQueue.main.async {
                settings = loaded
                isDirty = false
                if let completionMessage { lastActionMessage = completionMessage }
            }
        }
    }

    private func applySettings() {
        let toApply = settings
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            DockDefaultsManager.apply(toApply)
            DispatchQueue.main.async {
                isDirty = false
                isWorking = false
                lastActionMessage = "Applied changes and restarted the Dock."
            }
        }
    }

    private func addSpacer(_ size: DockDefaultsManager.SpacerSize) {
        DispatchQueue.global(qos: .userInitiated).async {
            DockDefaultsManager.addSpacer(size)
            DispatchQueue.main.async {
                lastActionMessage = "Added \(size == .small ? "small" : "large") spacer to the Dock."
            }
        }
    }

    private func apply(_ preset: SystemDockPreset) {
        let toApply = preset.settings(from: settings)
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            DockDefaultsManager.apply(toApply)
            DispatchQueue.main.async {
                settings = toApply
                isDirty = false
                isWorking = false
                lastActionMessage = "Applied \(preset.name)."
            }
        }
    }

    private func applyAccentColor() {
        isAccentWorking = true
        let chosen = accentColor
        DispatchQueue.global(qos: .userInitiated).async {
            chosen.apply()
            DispatchQueue.main.async {
                isAccentWorking = false
                lastActionMessage = "Set accent colour to \(chosen.label)."
            }
        }
    }

    /// A second, explicit confirmation in front of the actual hide -- this is a
    /// standing change to the real Dock that outlives Dawck quitting, so a
    /// single button press (a misclick, a stray automated event, a slip)
    /// should not be enough to trigger it on its own.
    private func enableReplacement() {
        let alert = NSAlert()
        alert.messageText = "Hide the real Dock and replace it?"
        alert.informativeText = "Your actual Dock will stop appearing, even on hover, until you undo this \u{2014} from here, or from System Settings \u{2192} Desktop & Dock. A themeable Dawck dock mirroring the same apps will take its place."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace the Dock")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isReplacementWorking = true
        SystemDockReplacement.hide {
            let dock = SystemDockReplacement.makeOrUpdateStandInDock(in: dockStore)
            isReplacementActive = true
            isReplacementWorking = false
            lastActionMessage = "Replaced the system Dock with \u{201C}\(dock.name)\u{201D}. Theme it from the Docks or Theme tab like any other dock."
        }
    }

    private func disableReplacement() {
        isReplacementWorking = true
        SystemDockReplacement.restore {
            isReplacementActive = false
            isReplacementWorking = false
            lastActionMessage = "Restored the real Dock. Your stand-in dock is still there if you want to keep using it alongside it."
        }
    }
}
