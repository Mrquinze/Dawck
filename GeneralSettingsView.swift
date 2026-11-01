import SwiftUI
import AppKit
import ServiceManagement

struct GeneralSettingsView: View {
    @AppStorage(AppPresentationDefaultsKey.mode) private var presentationModeRaw = AppPresentationMode.dockOnly.rawValue
    @AppStorage(AppPresentationDefaultsKey.menuMode) private var menuModeEnabled = true
    @ObservedObject private var backups = BackupManager.shared
    @State private var backupMessage: String?
    @State private var launchAtLogin = false
    @State private var loginItemError: String?

    private var presentationMode: Binding<AppPresentationMode> {
        Binding(
            get: { AppPresentationMode(rawValue: presentationModeRaw) ?? .dockOnly },
            set: { presentationModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Dawck Itself") {
                Picker("Show Dawck In", selection: presentationMode) {
                    ForEach(AppPresentationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Menu Bar Only hides Dawck's Dock icon. Use the menu bar item to reopen this window or quit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu Mode") {
                Toggle("List docks and actions in the menu bar", isOn: $menuModeEnabled)
                Text("Puts every dock and every action tile under Dawck's single menu bar icon, so you can run them without a floating dock on screen at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch Dawck at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginItemError {
                    Label(loginItemError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Welcome") {
                Button("Show What's New & Getting Started…") { WelcomeWindowController.shared.show(force: true) }
                Text("The tour that appears on first launch and after updates.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Backups") {
                HStack {
                    Button("Back Up Now") {
                        backupMessage = BackupManager.shared.backUp(automatic: false) ? "Backed up." : "Couldn't write a backup."
                    }
                    Spacer()
                    Text("Docks, themes and profiles. Dawck also keeps a daily copy when something has changed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(backups.backups.prefix(8)) { backup in
                    HStack {
                        Image(systemName: backup.isAutomatic ? "clock.arrow.circlepath" : "hand.tap")
                            .foregroundStyle(.secondary)
                        Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                        Text(backup.isAutomatic ? "Automatic" : "Manual").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore") { restore(backup) }.buttonStyle(.borderless)
                        Button(role: .destructive) { BackupManager.shared.delete(backup) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                if let backupMessage { Text(backupMessage).font(.caption).foregroundStyle(.secondary) }
            }

            Section("Permissions") {
                Label("Dawck asks for no special permissions up front", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
                Text("Dock Awareness reads only window owners and layers, never window contents or titles, so macOS never asks for Screen Recording or Accessibility access. Shortcut and AppleScript actions may prompt for permission to control the specific app they target.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshLaunchAtLogin() }
    }

    private func restore(_ backup: BackupManager.Info) {
        let alert = NSAlert()
        alert.messageText = "Restore this backup?"
        alert.informativeText = "Your docks, themes and profiles are replaced with the ones from \(backup.date.formatted(date: .abbreviated, time: .shortened)). The current setup is backed up first, so you can undo this."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try BackupManager.shared.restore(backup)
            backupMessage = "Restored."
        } catch {
            backupMessage = error.localizedDescription
        }
    }

    private func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// `SMAppService` throws when the app isn't in a location macOS will
    /// register (running straight out of a build folder, for instance), so the
    /// toggle reports the failure and snaps back rather than silently lying
    /// about having been set.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }
}
