import SwiftUI
import AppKit

/// Direct editing of the real Dock's contents. Every change here rewrites
/// `com.apple.dock` and restarts the Dock, which blanks it for about a second —
/// so edits are staged locally and committed on demand rather than applied per
/// keystroke, which would restart the Dock on every drag.
struct DockContentsView: View {
    @State private var apps: [SystemDockItems.Tile] = []
    @State private var others: [SystemDockItems.Tile] = []
    @State private var isDirty = false
    @State private var status: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("These are the tiles in your real Dock. Reorder them by dragging, remove them with the minus button, and commit when you're happy — each commit restarts the Dock.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                section(for: .apps, tiles: $apps)
                section(for: .others, tiles: $others)

                Section("Housekeeping") {
                    Button("Remove Tiles Whose Target Is Missing") {
                        let removed = SystemDockItems.removeMissing()
                        load()
                        status = removed == 0
                            ? "No missing tiles found."
                            : "Removed \(removed) missing tile\(removed == 1 ? "" : "s")."
                    }
                    Text("The Dock shows these as blank question marks and gives you no way to find them all.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let status {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reload from Dock") { load(message: "Reloaded from the Dock.") }
                Button("Apply & Restart Dock") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty)
            }
            .padding()
        }
        .onAppear { load() }
    }

    @ViewBuilder
    private func section(for section: SystemDockItems.Section, tiles: Binding<[SystemDockItems.Tile]>) -> some View {
        Section(section.label) {
            if tiles.wrappedValue.isEmpty {
                Text("Nothing in this part of the Dock.")
                    .foregroundStyle(.secondary)
            }

            ForEach(tiles) { $tile in
                TileRow(tile: $tile, onChange: { isDirty = true })
            }
            .onMove { source, destination in
                tiles.wrappedValue.move(fromOffsets: source, toOffset: destination)
                isDirty = true
            }
            .onDelete { offsets in
                tiles.wrappedValue.remove(atOffsets: offsets)
                isDirty = true
            }

            HStack {
                Button(section == .apps ? "Add Apps\u{2026}" : "Add Folders\u{2026}") {
                    add(to: section, tiles: tiles)
                }
                Button("Add Spacer") {
                    tiles.wrappedValue.append(spacer(small: false, in: section))
                    isDirty = true
                }
                Button("Add Small Spacer") {
                    tiles.wrappedValue.append(spacer(small: true, in: section))
                    isDirty = true
                }
            }
        }
    }

    private func spacer(small: Bool, in section: SystemDockItems.Section) -> SystemDockItems.Tile {
        SystemDockItems.Tile(
            id: UUID().uuidString,
            section: section,
            label: "",
            path: nil,
            isSpacer: true,
            isSmallSpacer: small,
            folderDisplay: .stack,
            folderView: .automatic
        )
    }

    private func add(to section: SystemDockItems.Section, tiles: Binding<[SystemDockItems.Tile]>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = section == .others
        panel.canChooseFiles = true
        panel.allowedContentTypes = section == .apps ? [.application] : [.folder]
        panel.directoryURL = URL(fileURLWithPath: section == .apps ? "/Applications" : NSHomeDirectory())
        guard panel.runModal() == .OK else { return }

        for url in panel.urls where !tiles.wrappedValue.contains(where: { $0.path == url.path }) {
            tiles.wrappedValue.append(SystemDockItems.Tile(
                id: UUID().uuidString,
                section: section,
                label: FileManager.default.displayName(atPath: url.path),
                path: url.path,
                isSpacer: false,
                isSmallSpacer: false,
                folderDisplay: .stack,
                folderView: .automatic
            ))
        }
        isDirty = true
    }

    /// Reads run off the main thread: `CFPreferences` on another app's domain
    /// can block while that app is mid-write, and the Dock rewrites its plist
    /// whenever it restarts.
    private func load(message: String? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let loadedApps = SystemDockItems.read(.apps)
            let loadedOthers = SystemDockItems.read(.others)
            DispatchQueue.main.async {
                apps = loadedApps
                others = loadedOthers
                isDirty = false
                if let message { status = message }
            }
        }
    }

    private func commit() {
        let appsToWrite = apps
        let othersToWrite = others
        DispatchQueue.global(qos: .userInitiated).async {
            // Both sections are written before the single restart, so
            // committing changes to apps and folders together doesn't blank the
            // Dock twice.
            SystemDockItems.write(appsToWrite, to: .apps, restart: false)
            SystemDockItems.write(othersToWrite, to: .others, restart: false)
            DockDefaultsManager.restartDock()
            DispatchQueue.main.async {
                isDirty = false
                status = "Applied and restarted the Dock."
                load()
            }
        }
    }
}

private struct TileRow: View {
    @Binding var tile: SystemDockItems.Tile
    let onChange: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(tile.displayName)
                    .lineLimit(1)
                if tile.isMissing {
                    Text("Missing \u{00B7} \(tile.path ?? "")")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else if let path = tile.path {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            // Only folder tiles have a presentation to choose; showing these on
            // an app tile would write keys the Dock reads as "this is a
            // directory" and render it as an empty stack.
            if tile.section == .others, !tile.isSpacer {
                Picker("", selection: $tile.folderView) {
                    ForEach(SystemDockItems.FolderView.allCases) { view in
                        Text(view.label).tag(view)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                .onChange(of: tile.folderView) { _, _ in onChange() }

                Picker("", selection: $tile.folderDisplay) {
                    ForEach(SystemDockItems.FolderDisplay.allCases) { display in
                        Text(display.label).tag(display)
                    }
                }
                .labelsHidden()
                .frame(width: 88)
                .onChange(of: tile.folderDisplay) { _, _ in onChange() }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if tile.isSpacer {
            Image(systemName: "space")
                .foregroundStyle(.secondary)
        } else if let image = tile.icon {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .opacity(tile.isMissing ? 0.4 : 1)
        }
    }
}
