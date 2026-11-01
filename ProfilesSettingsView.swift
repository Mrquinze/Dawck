import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProfilesSettingsView: View {
    @EnvironmentObject private var profileStore: DockProfileStore
    @EnvironmentObject private var dockStore: SecondaryDockStore
    @EnvironmentObject private var appSense: AppSenseStore

    @State private var newName = ""
    @State private var includeSystemDock = true
    @State private var isCapturing = false
    @State private var statusMessage: String?
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var newRuleProfileID: UUID?

    var body: some View {
        Form {
            Section {
                Text("A profile is a snapshot of your whole setup — the system Dock's settings, every custom dock, and the current theme. Switch between them in one click from here or from the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Capture Current Setup") {
                TextField("Profile name", text: $newName, prompt: Text("Desk, Laptop, Presenting\u{2026}"))
                Toggle("Include the system Dock's settings", isOn: $includeSystemDock)
                Text(includeSystemDock
                     ? "Applying this profile will restart the Dock, which blanks it for about a second."
                     : "This profile will only change Dawck's own docks and theme — the system Dock is left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save as Profile") { capture() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || isCapturing)
            }

            Section("Your Profiles") {
                if profileStore.profiles.isEmpty {
                    Text("No profiles yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(profileStore.profiles) { profile in
                    row(for: profile)
                }
            }

            Section("AppSense") {
                Toggle("Switch profile automatically when an app comes forward", isOn: $appSense.isEnabled)
                Text("Focus Xcode and your dev layout appears; focus Mail and it doesn't. Costs no permission — macOS tells any app which app is frontmost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appSense.isEnabled {
                    if profileStore.profiles.isEmpty {
                        Text("Save at least one profile above to build a rule.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appSense.rules) { rule in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: appPath(for: rule) ?? "/Applications"))
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(width: 18, height: 18)
                                Text(rule.appName)
                                Spacer()
                                Text(profileStore.profiles.first { $0.id == rule.profileID }?.name ?? "Deleted profile")
                                    .foregroundStyle(.secondary)
                                Button(role: .destructive) {
                                    appSense.remove(rule)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        HStack {
                            Picker("Then apply", selection: $newRuleProfileID) {
                                Text("Choose a profile\u{2026}").tag(UUID?.none)
                                ForEach(profileStore.profiles) { profile in
                                    Text(profile.name).tag(Optional(profile.id))
                                }
                            }
                            Button("Add App\u{2026}") { addRule() }
                                .disabled(newRuleProfileID == nil)
                        }

                        Toggle("Apply a default profile for every other app", isOn: $appSense.usesFallback)
                        if appSense.usesFallback {
                            Picker("Default profile", selection: $appSense.fallbackProfileID) {
                                Text("None").tag(UUID?.none)
                                ForEach(profileStore.profiles) { profile in
                                    Text(profile.name).tag(Optional(profile.id))
                                }
                            }
                        }
                    }
                }
            }

            Section("Transfer") {
                Text("Profiles export as plain JSON — the simplest way to move a setup to another Mac, or to keep a backup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Import Profile\u{2026}") { importProfile() }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func row(for profile: DockProfile) -> some View {
        HStack(spacing: 12) {
            GlassSwatch(theme: profile.theme, scale: 0.45)
                .frame(width: 46, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                if renamingID == profile.id {
                    TextField("Name", text: $renameText)
                        .onSubmit { commitRename(profile) }
                } else {
                    Text(profile.name)
                }
                Text(subtitle(for: profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if profileStore.activeProfileID == profile.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Most recently applied")
            }

            Button("Apply") { apply(profile) }

            Menu {
                Button("Update from Current Setup") {
                    profileStore.updateFromCurrentState(profile) {
                        statusMessage = "Updated \u{201C}\(profile.name)\u{201D} from the current setup."
                    }
                }
                Button("Rename") {
                    renameText = profile.name
                    renamingID = profile.id
                }
                Button("Export\u{2026}") { export(profile) }
                Divider()
                Button("Delete", role: .destructive) { profileStore.delete(profile) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func subtitle(for profile: DockProfile) -> String {
        var parts = ["\(profile.docks.count) dock\(profile.docks.count == 1 ? "" : "s")", profile.theme.name]
        parts.append(profile.includesSystemDock ? "includes system Dock" : "docks and theme only")
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Actions

    private func capture() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isCapturing = true
        profileStore.capture(named: name, includeSystemDock: includeSystemDock) { profile in
            isCapturing = false
            newName = ""
            statusMessage = "Saved \u{201C}\(profile.name)\u{201D}."
        }
    }

    private func apply(_ profile: DockProfile) {
        statusMessage = "Applying \u{201C}\(profile.name)\u{201D}\u{2026}"
        profileStore.apply(profile) {
            statusMessage = "Applied \u{201C}\(profile.name)\u{201D}."
        }
    }

    private func appPath(for rule: AppSenseRule) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleIdentifier)?.path
    }

    private func addRule() {
        guard let profileID = newRuleProfileID else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            statusMessage = "That app has no bundle identifier, so it can't be matched."
            return
        }
        appSense.add(
            bundleIdentifier: bundleID,
            appName: FileManager.default.displayName(atPath: url.path),
            profileID: profileID
        )
        newRuleProfileID = nil
    }

    private func commitRename(_ profile: DockProfile) {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { profileStore.rename(profile, to: name) }
        renamingID = nil
    }

    private func export(_ profile: DockProfile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name).dawckprofile.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try profileStore.export(profile, to: url)
            statusMessage = "Exported to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let profile = try profileStore.importProfile(from: url)
            let pending = profile.untrustedActionCount
            statusMessage = "Imported \u{201C}\(profile.name)\u{201D}." + (pending > 0
                ? " \(pending) action\(pending == 1 ? " is" : "s are") switched off until you approve \(pending == 1 ? "it" : "them") on the dock."
                : "")
        } catch {
            statusMessage = "Couldn't import that file: \(error.localizedDescription)"
        }
    }
}
