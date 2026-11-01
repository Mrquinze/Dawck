import SwiftUI

struct MenuBarSettingsView: View {
    @EnvironmentObject private var clusterStore: MenuBarClusterStore
    @EnvironmentObject private var dockStore: SecondaryDockStore

    var body: some View {
        Form {
            Section {
                Text("Clusters let you fold groups of menu bar icons away by name, instead of one blanket \u{201C}hidden\u{201D} pile.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("How to fill a cluster") {
                Label {
                    Text("Add a cluster below. A handle appears in your menu bar.")
                } icon: {
                    Text("1").font(.caption.bold()).frame(width: 16)
                }
                Label {
                    Text("Hold \u{2318} and drag your menu bar icons so the ones you want in that cluster sit to the **left** of its handle.")
                } icon: {
                    Text("2").font(.caption.bold()).frame(width: 16)
                }
                Label {
                    Text("Click the handle to fold that cluster away, or click it again to bring it back.")
                } icon: {
                    Text("3").font(.caption.bold()).frame(width: 16)
                }
            }

            Section("Your Clusters") {
                if clusterStore.clusters.isEmpty {
                    Text("No clusters yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach($clusterStore.clusters) { $cluster in
                    ClusterRow(cluster: $cluster) { clusterStore.remove(cluster) }
                }

                HStack {
                    Button("Add Cluster") { clusterStore.add() }
                    Spacer()
                    Button("Reveal All") { clusterStore.revealAll() }
                        .disabled(clusterStore.clusters.allSatisfy { !$0.isCollapsed })
                    Button("Hide All") { clusterStore.collapseAll() }
                        .disabled(clusterStore.clusters.allSatisfy(\.isCollapsed))
                }
            }

            Section("Ordering") {
                Label(
                    "Clusters nest from the right. Folding one also folds anything further left.",
                    systemImage: "arrow.left.to.line"
                )
                .foregroundStyle(.secondary)
                Text("This isn't a limitation Dawck can design around. macOS lays the menu bar out right to left, and widening an icon only pushes what's to its left — so the rightmost cluster is necessarily the outermost one. Reaching individual icons in any order would mean driving the Accessibility API, which is the permission this app is built to do without. Put the group you fold most often furthest right.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Inline Actions") {
                Text("A dock can also place its app and action tiles directly in the menu bar as individual icons, rather than under Dawck's single icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if dockStore.docks.isEmpty {
                    Text("No docks to place yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach($dockStore.docks) { $dock in
                    Toggle(isOn: $dock.showsInlineMenuBarItems) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dock.name)
                            Text(inlineCaption(for: dock))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func inlineCaption(for dock: SecondaryDock) -> String {
        let count = dock.items.filter { $0.kind == .action || $0.kind == .file }.count
        return "\(count) tile\(count == 1 ? "" : "s") eligible \u{00B7} up to 12 placed in total"
    }
}

private struct ClusterRow: View {
    @Binding var cluster: MenuBarCluster
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: cluster.symbol)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)

                TextField("Name", text: $cluster.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                Picker("", selection: $cluster.symbol) {
                    ForEach(MenuBarCluster.symbolChoices, id: \.self) { symbol in
                        Image(systemName: symbol).tag(symbol)
                    }
                }
                .labelsHidden()
                .frame(width: 62)

                Spacer()

                Button(cluster.isCollapsed ? "Reveal" : "Hide") {
                    cluster.isCollapsed.toggle()
                }
                .frame(width: 66)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 14) {
                Toggle("Fold at launch", isOn: $cluster.collapsesAtLaunch)
                    .toggleStyle(.checkbox)

                HStack(spacing: 6) {
                    Text("Re-fold after")
                        .font(.callout)
                    // 0 is a real setting here, not a missing one, so the
                    // slider's floor reads as "stay open" rather than "0
                    // seconds", which would mean folding instantly.
                    Slider(value: $cluster.autoCollapseDelay, in: 0...60, step: 1)
                        .frame(width: 130)
                    Text(cluster.autoCollapseDelay == 0
                         ? "never"
                         : "\(Int(cluster.autoCollapseDelay))s")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                }
            }
            .padding(.leading, 30)
        }
        .padding(.vertical, 2)
    }
}
