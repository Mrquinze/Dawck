import SwiftUI

struct HotCornersView: View {
    @State private var settings: [ScreenCorner: HotCornerSetting] = [:]
    @State private var appBindings: [ScreenCorner: String] = [:]
    @State private var isDirty = false
    @State private var status: String?

    /// A sentinel action id standing in for "open an app" in the picker, kept
    /// out of `HotCornerAction` itself since that enum's raw values are the
    /// real `wvous-*-corner` integers macOS understands -- this one has no
    /// native equivalent.
    private static let openAppTag = -1

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("What happens when you push the pointer into a corner of the screen. Hold a modifier to make a corner harder to trigger by accident.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Corners") {
                    ForEach(ScreenCorner.allCases) { corner in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Image(systemName: symbol(for: corner))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(corner.label)
                                    .frame(width: 96, alignment: .leading)

                                Picker("", selection: actionSelection(for: corner)) {
                                    ForEach(HotCornerAction.allCases) { action in
                                        Text(action.label).tag(action.rawValue)
                                    }
                                    Divider()
                                    Text("Open an App...").tag(Self.openAppTag)
                                }
                                .labelsHidden()

                                Picker("", selection: binding(for: corner).modifier) {
                                    ForEach(HotCornerModifier.allCases) { modifier in
                                        Text(modifier.label).tag(modifier)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 132)
                                // A modifier with no action is a setting that can
                                // never fire, so it's disabled rather than left to
                                // look configured. An app binding has no modifier
                                // of its own either -- the watcher fires on any
                                // approach, so a required-modifier reading here
                                // would be a lie.
                                .disabled(settings[corner]?.action == HotCornerAction.none || appBindings[corner] != nil)
                            }

                            if let path = appBindings[corner] {
                                HStack(spacing: 10) {
                                    Color.clear.frame(width: 20)
                                    Image(nsImage: IconProvider.shared.icon(forPath: path, size: 20))
                                        .resizable().aspectRatio(contentMode: .fit)
                                        .frame(width: 16, height: 16)
                                    Text((path as NSString).lastPathComponent)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Change...") { chooseApp(for: corner) }
                                    Button("Remove") { removeAppBinding(for: corner) }
                                }
                                .padding(.leading, 106)
                            }
                        }
                    }

                    Text("An app-launch corner has no native macOS action of its own, so Dawck watches for the pointer reaching it. That watcher only runs while at least one corner has an app assigned.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let status {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reload") { load(message: "Reloaded hot corners.") }
                Button("Apply & Restart Dock") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty)
            }
            .padding()
        }
        .onAppear { load() }
    }

    private func symbol(for corner: ScreenCorner) -> String {
        switch corner {
        case .topLeft: return "arrow.up.left.square"
        case .topRight: return "arrow.up.right.square"
        case .bottomLeft: return "arrow.down.left.square"
        case .bottomRight: return "arrow.down.right.square"
        }
    }

    /// Bridges the picker between the native `HotCornerAction` cases and the
    /// synthetic "Open an App" entry, and drives the file picker + native
    /// action clearing when the user actually picks it.
    private func actionSelection(for corner: ScreenCorner) -> Binding<Int> {
        Binding(
            get: {
                appBindings[corner] != nil ? Self.openAppTag : (settings[corner]?.action ?? .none).rawValue
            },
            set: { newValue in
                if newValue == Self.openAppTag {
                    chooseApp(for: corner)
                } else if let action = HotCornerAction(rawValue: newValue) {
                    removeAppBinding(for: corner)
                    binding(for: corner).action.wrappedValue = action
                }
            }
        )
    }

    private func chooseApp(for corner: ScreenCorner) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        appBindings[corner] = url.path
        // The OS mustn't also fire a native action at the same corner -- that
        // would mean pushing into it does two unrelated things at once.
        settings[corner, default: HotCornerSetting()].action = .none
        isDirty = true
    }

    private func removeAppBinding(for corner: ScreenCorner) {
        guard appBindings[corner] != nil else { return }
        appBindings.removeValue(forKey: corner)
        isDirty = true
    }

    private func binding(for corner: ScreenCorner) -> Binding<HotCornerSetting> {
        Binding(
            get: { settings[corner] ?? HotCornerSetting() },
            set: { newValue in
                settings[corner] = newValue
                isDirty = true
            }
        )
    }

    private func load(message: String? = nil) {
        appBindings = HotCornerAppBindings.read()
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = HotCorners.read()
            DispatchQueue.main.async {
                settings = loaded
                isDirty = false
                if let message { status = message }
            }
        }
    }

    private func apply() {
        let toApply = settings
        let toApplyBindings = appBindings
        DispatchQueue.global(qos: .userInitiated).async {
            HotCorners.write(toApply)
            DispatchQueue.main.async {
                HotCornerAppBindings.write(toApplyBindings)
                isDirty = false
                status = "Applied hot corners and restarted the Dock."
            }
        }
    }
}
