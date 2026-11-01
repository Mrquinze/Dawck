import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DocksSettingsView: View {
    @EnvironmentObject private var store: SecondaryDockStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var editingDock: SecondaryDock?
    /// Docks created by the "New Dock" button, so cancelling the editor can
    /// remove them again. Without this, cancelling a brand-new dock left an
    /// unwanted empty dock behind — it had already been appended to the store
    /// in order to be edited.
    @State private var provisionalDockID: UUID?

    var body: some View {
        Form {
            Section {
                Text("Docks are floating tile bars Dawck draws itself, separate from the system Dock. They stay on screen after this window closes, and each one can sit on its own display and edge.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Your Docks") {
                if store.docks.isEmpty {
                    Text("No docks yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.docks) { dock in
                    DockRow(dock: dock, onEdit: { editingDock = dock })
                }

                HStack {
                    Button("New Dock") {
                        let dock = store.addDock()
                        provisionalDockID = dock.id
                        editingDock = dock
                    }
                    Button("New Mirror of System Dock") {
                        var dock = SecondaryDock(
                            name: "Dock Mirror",
                            edge: .top,
                            contentMode: .liveDock
                        )
                        dock.id = UUID()
                        store.docks.append(dock)
                        provisionalDockID = dock.id
                        editingDock = dock
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingDock) { dock in
            DockEditorView(
                dock: dock,
                store: store,
                themeStore: themeStore,
                onCancel: {
                    if provisionalDockID == dock.id {
                        store.remove(dock)
                    }
                    provisionalDockID = nil
                },
                onSave: { provisionalDockID = nil }
            )
        }
    }
}

private struct DockRow: View {
    let dock: SecondaryDock
    let onEdit: () -> Void

    @EnvironmentObject private var store: SecondaryDockStore

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { dock.isEnabled },
                set: { newValue in
                    var updated = dock
                    updated.isEnabled = newValue
                    store.update(updated)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dock.name)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Edit", action: onEdit)
            Menu {
                Button("Duplicate") { store.duplicate(dock) }
                Divider()
                Button("Delete", role: .destructive) { store.remove(dock) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var subtitle: String {
        var parts = [dock.edge.label, dock.display.name]
        if dock.contentMode == .liveDock {
            parts.append("mirroring the Dock")
        } else {
            parts.append("\(dock.items.count) tile\(dock.items.count == 1 ? "" : "s")")
        }
        if !dock.display.isConnected { parts.append("display not connected") }
        if dock.collapseMode.isEnabled { parts.append("collapsing") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Editor

private struct DockEditorView: View {
    @State var dock: SecondaryDock
    let store: SecondaryDockStore
    let themeStore: ThemeStore
    let onCancel: () -> Void
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editingItem: DockItem?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    TextField("Name", text: $dock.name)
                    Toggle("Enabled", isOn: $dock.isEnabled)
                }

                Section("Placement") {
                    Picker("Screen Edge", selection: $dock.edge) {
                        ForEach(DockEdge.allCases) { edge in
                            Text(edge.label).tag(edge)
                        }
                    }
                    Toggle("Show on Every Display", isOn: $dock.showsOnAllScreens)
                    Picker("Display", selection: displaySelection) {
                        ForEach(screenOptions, id: \.key) { option in
                            Text(option.name).tag(option.key)
                        }
                    }
                    .disabled(dock.showsOnAllScreens)
                    Picker("Stacking", selection: $dock.windowLevel) {
                        ForEach(DockLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    LabeledContent(dock.edge.isHorizontal ? "Position (left to right)" : "Position (top to bottom)") {
                        ValueSlider(value: $dock.alignment, range: 0...1, step: 0.01, format: "%.2f")
                    }
                    LabeledContent("Distance from Edge") {
                        ValueSlider(value: $dock.edgeMargin, range: 0...80, step: 1, format: "%.0f pt")
                    }
                }

                Section("Contents") {
                    Picker("Show", selection: $dock.contentMode) {
                        ForEach(DockContentMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Text(dock.contentMode.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Appearance") {
                    LabeledContent("Tile Size") {
                        ValueSlider(value: $dock.tileSize, range: 24...96, step: 1, format: "%.0f pt")
                    }
                    Toggle("Magnify on Hover", isOn: $dock.magnificationEnabled)
                        .disabled(dock.hoverStyle != .magnify)
                    if dock.magnificationEnabled, dock.hoverStyle == .magnify {
                        LabeledContent("Magnified Size") {
                            ValueSlider(value: $dock.magnifiedTileSize, range: 24...140, step: 1, format: "%.0f pt")
                        }
                    }
                    Picker("Spacing", selection: $dock.spacing) {
                        ForEach(SpacingPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Layout", selection: $dock.layoutMode) {
                        ForEach(DockLayoutMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Picker("On Hover", selection: $dock.hoverStyle) {
                        ForEach(HoverStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    Toggle("Show Running Indicators", isOn: $dock.showsRunningIndicators)
                    if dock.showsRunningIndicators {
                        Picker("Indicator", selection: $dock.indicatorStyle) {
                            ForEach(IndicatorStyle.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        ColorPicker("Indicator Colour", selection: Binding(
                            get: { dock.indicatorColor.color },
                            set: { dock.indicatorColor = CodableColor(color: $0) }
                        ), supportsOpacity: false)
                    }
                    Toggle("Grey Out Apps That Aren't Running", isOn: $dock.dimsNonRunningApps)
                    Toggle("Show Tile Labels", isOn: $dock.showsLabels)
                    Picker("Theme", selection: Binding(
                        get: { dock.themeOverrideID ?? Self.followActiveTag },
                        set: { dock.themeOverrideID = $0 == Self.followActiveTag ? nil : $0 }
                    )) {
                        Text("Follow Active Theme").tag(Self.followActiveTag)
                        ForEach(themeStore.saved) { saved in
                            Text(saved.name).tag(saved.id)
                        }
                    }
                }

                Section("Showing & Hiding") {
                    Picker("When Idle", selection: $dock.collapseMode) {
                        ForEach(DockCollapseMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    if dock.collapseMode.isEnabled {
                        LabeledContent("Collapse After") {
                            ValueSlider(value: $dock.collapseDelay, range: 0...5, step: 0.1, format: "%.1f s")
                        }
                    }
                    if dock.collapseMode.collapsesToButton {
                        TextField("Button Text", text: $dock.collapseGlyph, prompt: Text("Up to 3 characters, or leave blank for a chevron"))
                            .onChange(of: dock.collapseGlyph) { _, newValue in
                                if newValue.count > 3 { dock.collapseGlyph = String(newValue.prefix(3)) }
                            }
                    }
                    Toggle("Hide While an App Is Full Screen", isOn: $dock.hidesInFullscreen)
                    Toggle("Hide When a Window Covers It", isOn: $dock.hidesOnWindowOverlap)
                    if dock.hidesInFullscreen || dock.hidesOnWindowOverlap || dock.collapseMode == .fadeOut {
                        Toggle("Bring It Back at the Screen Edge", isOn: $dock.revealsAtEdgeWhenHidden)
                        Picker("Edge Sensitivity", selection: $dock.revealZone) {
                            ForEach(RevealZone.allCases) { zone in
                                Text(zone.label).tag(zone)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    Picker("Appear & Disappear", selection: $dock.appearAnimation) {
                        ForEach(AppearAnimation.allCases) { animation in
                            Text(animation.label).tag(animation)
                        }
                    }
                    LabeledContent("Show / Hide Shortcut") {
                        HotKeyRecorder(spec: $dock.hotkey)
                    }
                }

                if dock.contentMode == .manual {
                    Section("Protection") {
                        Toggle("Lock This Dock", isOn: $dock.isLocked)
                        Text("A locked dock can't be rearranged or have things dropped onto it by accident. Right-click it and choose Edit Dock to change it, or change it here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if dock.contentMode == .liveDock {
                    Section("Tiles") {
                        Label("This dock mirrors your real Dock, so its tiles come from there.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        ForEach(dock.hiddenBundleIDs, id: \.self) { bundleID in
                            HStack {
                                Text(Self.appName(for: bundleID))
                                Spacer()
                                Button("Show Again") { dock.hiddenBundleIDs.removeAll { $0 == bundleID } }
                                    .buttonStyle(.borderless)
                            }
                        }
                        if dock.hiddenBundleIDs.isEmpty {
                            Text("Right-click any tile on the mirror and choose Hide to take it off this display only.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section("Tiles") {
                        if dock.items.isEmpty {
                            Text("No tiles yet. Add apps, folders, actions, or live widgets.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach($dock.items) { $item in
                            TileRow(item: $item) { editingItem = item }
                        }
                        .onMove { source, destination in
                            dock.items.move(fromOffsets: source, toOffset: destination)
                        }
                        .onDelete { offsets in
                            dock.items.remove(atOffsets: offsets)
                        }

                        HStack {
                            Button("Add Apps or Folders\u{2026}") { addFiles() }
                            Menu("Add Other") {
                                Button("Action\u{2026}") { addItem(kind: .action) }
                                Button("Widget\u{2026}") { addItem(kind: .widget) }
                                Button("App Group") { addItem(kind: .group) }
                                Button("File Tray") { addItem(kind: .tray) }
                                Button("Trash") { addItem(kind: .trash) }
                                Button("Spacer") { addItem(kind: .separator) }
                            }
                            .fixedSize()
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                Spacer()
                Button("Save") {
                    store.update(dock)
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 640)
        .sheet(item: $editingItem) { item in
            TileEditorView(item: item) { updated in
                guard let index = dock.items.firstIndex(where: { $0.id == updated.id }) else { return }
                dock.items[index] = updated
            }
        }
    }

    /// A sentinel UUID standing for "no override". A `Picker` needs every tag
    /// to be the same type, and `UUID?` tags interact badly with `ForEach` over
    /// non-optional ids, so the nil case gets its own constant instead.
    private static let followActiveTag = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // MARK: Display picker

    private struct ScreenOption {
        let key: String
        let name: String
        let identity: DisplayIdentity?
    }

    /// Connected displays, plus the dock's current display if it isn't one of
    /// them (e.g. an external monitor that's unplugged right now) — so the
    /// picker never silently reassigns the dock to a different screen just
    /// because that screen wasn't connected when the editor opened.
    private var screenOptions: [ScreenOption] {
        var options = NSScreen.screens.map { screen in
            let identity = DisplayIdentity(screen: screen)
            return ScreenOption(key: Self.key(for: identity), name: screen.localizedName, identity: identity)
        }
        let currentKey = Self.key(for: dock.display)
        if !options.contains(where: { $0.key == currentKey }) {
            options.append(ScreenOption(
                key: currentKey,
                name: "\(dock.display.name) (not connected)",
                identity: dock.display
            ))
        }
        return options
    }

    private static func key(for identity: DisplayIdentity) -> String {
        identity.uuid ?? "id:\(identity.displayID)"
    }

    private var displaySelection: Binding<String> {
        Binding(
            get: { Self.key(for: dock.display) },
            set: { newKey in
                guard let match = screenOptions.first(where: { $0.key == newKey }),
                      let identity = match.identity else { return }
                dock.display = identity
            }
        )
    }

    // MARK: Tile creation

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application, .folder]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !dock.items.contains(where: { $0.kind == .file && $0.path == url.path }) {
            dock.items.append(DockItem(path: url.path))
        }
    }

    private func addItem(kind: DockItemKind) {
        let item = DockItem(kind: kind)
        dock.items.append(item)
        if kind != .separator, kind != .trash { editingItem = item }
    }

    private static func appName(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }
}

// MARK: - Tile row

private struct TileRow: View {
    @Binding var item: DockItem
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(item.isMissing ? Color.orange : Color.secondary)
            }
            Spacer()
            if item.kind != .separator {
                Button("Edit", action: onEdit)
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item.kind {
        case .file:
            if let image = IconProvider.shared.icon(for: item, size: 32) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        default:
            Image(systemName: item.symbolName)
                .foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        if item.isMissing { return "Missing — the file is no longer at \(item.path)" }
        switch item.kind {
        case .file: return item.path
        case .action: return item.actionType.label
        case .widget: return "Live widget"
        case .separator: return "Spacer"
        case .tray: return "\(item.memberPaths.count) file\(item.memberPaths.count == 1 ? "" : "s") staged"
        case .group: return "\(item.memberPaths.count) app\(item.memberPaths.count == 1 ? "" : "s")"
        case .trash: return "Trash"
        }
    }
}

// MARK: - Tile editor

private struct TileEditorView: View {
    @State var item: DockItem
    let onSave: (DockItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var testResult: String?
    @State private var cityMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Type") {
                    Picker("Tile Type", selection: $item.kind) {
                        ForEach(DockItemKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch item.kind {
                case .file:
                    fileSection
                case .action:
                    actionSection
                case .widget:
                    widgetSection
                case .separator:
                    Section {
                        Text("A spacer leaves a gap between tiles. It has nothing to configure.")
                            .foregroundStyle(.secondary)
                    }
                case .tray:
                    Section("File Tray") {
                        Text("A staging shelf. Drag files onto the tray tile to park them, click it to see what's inside, and drag them back out wherever you need them. Its contents survive relaunches.")
                            .foregroundStyle(.secondary)
                        if !item.memberPaths.isEmpty {
                            Text("\(item.memberPaths.count) file\(item.memberPaths.count == 1 ? "" : "s") staged")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Empty Tray", role: .destructive) { item.memberPaths.removeAll() }
                        }
                    }
                case .group:
                    Section("Apps in This Group") {
                        if item.memberPaths.isEmpty {
                            Text("No apps yet. A group folds several apps behind one tile and fans them out on click.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(item.memberPaths, id: \.self) { path in
                            HStack {
                                Image(nsImage: IconProvider.shared.icon(forPath: path, size: 32))
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 20)
                                Text(FileManager.default.displayName(atPath: path))
                                Spacer()
                                Button(role: .destructive) {
                                    item.memberPaths.removeAll { $0 == path }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Add Apps\u{2026}") { addMembers() }
                    }
                case .trash:
                    Section("Trash") {
                        Text("Opens the Trash, accepts dropped files to throw them away, and can empty it. The icon shows whether anything is inside.")
                            .foregroundStyle(.secondary)
                    }
                }

                if item.kind != .separator {
                    Section("Appearance") {
                        TextField("Custom Name", text: Binding(
                            get: { item.customName ?? "" },
                            set: { item.customName = $0.isEmpty ? nil : $0 }
                        ), prompt: Text(item.kind == .file ? "Leave blank to use the file's name" : "Leave blank to use the default"))
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(testResult.hasPrefix("Ran") ? Color.secondary : Color.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(item)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    // MARK: Sections

    private var fileSection: some View {
        Section("Target") {
            LabeledContent("Path") {
                HStack {
                    Text(item.path.isEmpty ? "Nothing chosen" : item.path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(item.path.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choose\u{2026}") { chooseFile() }
                }
            }
            LabeledContent("Custom Icon") {
                HStack {
                    Text(item.customIconPath ?? "Using the file's own icon")
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(item.customIconPath == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose\u{2026}") { chooseIcon() }
                    if item.customIconPath != nil {
                        Button("Clear") { item.customIconPath = nil }
                    }
                }
            }
        }
    }

    private var actionSection: some View {
        Section("Action") {
            if !item.isTrusted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("This action came from an imported profile and is switched off.", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Text("Read what it does below. Only approve it if you wrote it or trust whoever sent it — shell commands and scripts can do anything you can.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("I've Read It — Approve") { item.isTrusted = true }
                }
            }
            Picker("Kind", selection: $item.actionType) {
                ForEach(DockActionType.allCases) { type in
                    Text(type.label).tag(type)
                }
            }

            if item.actionType == .appleScript || item.actionType == .shell {
                TextEditor(text: $item.actionPayload)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
            } else {
                TextField(item.actionType.label, text: $item.actionPayload, prompt: Text(item.actionType.placeholder))
                    .textFieldStyle(.roundedBorder)
            }

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("SF Symbol", text: $item.actionSymbol, prompt: Text(item.actionType.defaultSymbol))
                .textFieldStyle(.roundedBorder)

            HStack {
                Image(systemName: item.symbolName)
                    .font(.title2)
                    .frame(width: 32, height: 32)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Spacer()
                Button("Test This Action") { test() }
                    .disabled(item.actionPayload.trimmingCharacters(in: .whitespaces).isEmpty || !item.isTrusted)
            }
        }
    }

    private var widgetSection: some View {
        Group {
            Section("Widget") {
                Picker("Reading", selection: $item.widget) {
                    ForEach(DockWidgetKind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbol).tag(kind)
                    }
                }
                .pickerStyle(.inline)
                Text(item.widget.blurb).font(.caption).foregroundStyle(.secondary)
            }
            widgetOptionsSection
        }
    }

    @ViewBuilder
    private var widgetOptionsSection: some View {
        let kind = item.widget
        if kind.supportsGraph || [.clock, .analogClock, .worldClock, .countdown, .weather, .ip].contains(kind) {
            Section("Options") {
                if kind.supportsGraph {
                    Picker("Show", selection: $item.widgetOptions.style) {
                        ForEach(WidgetStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if [.clock, .analogClock, .worldClock].contains(kind) {
                    Toggle("Show Seconds", isOn: $item.widgetOptions.showsSeconds)
                }
                if kind == .clock || kind == .worldClock {
                    Picker("Hours", selection: Binding(get: { item.widgetOptions.use24Hour.map { $0 ? 2 : 1 } ?? 0 },
                                                      set: { item.widgetOptions.use24Hour = $0 == 0 ? nil : $0 == 2 })) {
                        Text("System").tag(0); Text("12-hour").tag(1); Text("24-hour").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                if kind == .worldClock {
                    Picker("City", selection: $item.widgetOptions.timeZoneID) {
                        Text("Choose…").tag("")
                        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                    }
                }
                if kind == .countdown {
                    Stepper("Length: \(item.widgetOptions.countdownMinutes) min", value: $item.widgetOptions.countdownMinutes, in: 1...600)
                }
                if kind == .ip {
                    Picker("Address", selection: $item.widgetOptions.ipMode) {
                        ForEach(IPDisplayMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if item.widgetOptions.ipMode != .local {
                        Label("The public address is looked up over the internet, at most every ten minutes.", systemImage: "globe")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if kind == .weather { weatherOptions }
            }
        }
    }

    @ViewBuilder
    private var weatherOptions: some View {
        HStack {
            TextField("City", text: $item.widgetOptions.city, prompt: Text("Lisbon"))
                .onSubmit { Task { await lookUpCity() } }
            Button("Find") { Task { await lookUpCity() } }
                .disabled(item.widgetOptions.city.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if item.widgetOptions.latitude != nil {
            Label("Location set.", systemImage: "location.fill").font(.caption).foregroundStyle(.secondary)
        }
        if let cityMessage { Text(cityMessage).font(.caption).foregroundStyle(.orange) }
        Picker("Units", selection: $item.widgetOptions.fahrenheit) {
            Text("Celsius").tag(false); Text("Fahrenheit").tag(true)
        }
        .pickerStyle(.segmented)
        Label("Weather comes from Open-Meteo over the internet, refreshed every 30 minutes while the dock is showing. Only the city's coordinates are sent.", systemImage: "globe")
            .font(.caption).foregroundStyle(.secondary)
    }

    @MainActor
    private func lookUpCity() async {
        let query = item.widgetOptions.city.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        cityMessage = "Looking up…"
        if let result = await WidgetHub.geocode(query) {
            item.widgetOptions.city = result.name
            item.widgetOptions.latitude = result.latitude
            item.widgetOptions.longitude = result.longitude
            cityMessage = nil
        } else {
            cityMessage = "Couldn't find “\(query)”."
        }
    }

    private var hint: String {
        switch item.actionType {
        case .url:
            return "Any URL macOS can open, including app deep links: spotify:playlist:…, slack://channel?team=…, raycast://…, things:///show?id=…, or a plain https:// address."
        case .shortcut:
            return "The exact name of a shortcut in the Shortcuts app. The first run may ask that app for permission."
        case .shell:
            return "Runs under your login shell, so Homebrew and anything else on your PATH is available."
        case .appleScript:
            return "Runs as AppleScript. Controlling another app may prompt for Automation permission the first time."
        }
    }

    // MARK: Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application, .folder]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            item.path = url.path
        }
    }

    private func addMembers() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !item.memberPaths.contains(url.path) {
            item.memberPaths.append(url.path)
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            item.customIconPath = url.path
        }
    }

    private func test() {
        testResult = "Running\u{2026}"
        ActionRunner.run(item) { failure in
            testResult = failure?.errorDescription ?? "Ran without error."
        }
    }
}
