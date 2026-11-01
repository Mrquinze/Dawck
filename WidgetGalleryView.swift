import SwiftUI

/// Every widget Dawck can put on a dock, with a picture of what it looks like.
/// The pictures use fixed example readings, so browsing the gallery measures
/// nothing and costs nothing.
struct WidgetGalleryView: View {
    @EnvironmentObject private var store: SecondaryDockStore
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var addedMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                GlassSection(title: "Widgets", symbol: "square.grid.2x2",
                             footnote: "Widgets only measure while they are on a dock that is showing. A widget marked with a globe reaches out to the internet, and only does so when it is on a dock.") {
                    Text("Add any of these to a dock. Click a widget on the dock to use it — stopwatches start, the volume mutes, the calendar opens, and so on.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let addedMessage { Label(addedMessage, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout) }
                }
                ForEach(DockWidgetKind.Category.allCases) { category in
                    GlassSection(title: category.rawValue) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                            ForEach(DockWidgetKind.allCases.filter { $0.category == category }) { kind in
                                WidgetCard(kind: kind, theme: themeStore.active, docks: store.docks) { dockID in add(kind, to: dockID) }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background { AmbientBackdrop() }
    }

    private func add(_ kind: DockWidgetKind, to dockID: UUID?) {
        var item = DockItem(kind: .widget)
        item.widget = kind
        let id: UUID
        if let dockID {
            id = dockID
        } else {
            let dock = store.addDock()
            id = dock.id
        }
        store.appendItem(item, to: id)
        let name = store.docks.first { $0.id == id }?.name ?? "your dock"
        addedMessage = "Added \(kind.label) to \(name)."
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { addedMessage = nil }
    }
}

private struct WidgetCard: View {
    let kind: DockWidgetKind
    let theme: GlassTheme
    let docks: [SecondaryDock]
    let add: (UUID?) -> Void

    var body: some View {
        HStack(spacing: 14) {
            WidgetFace(kind: kind, snapshot: WidgetSamples.snapshot(for: kind), options: WidgetOptions(), side: 64,
                       foreground: .primary, accent: .accentColor)
                .frame(width: 64, height: 64)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(kind.label).font(.headline)
                    if kind.usesInternet { Image(systemName: "globe").font(.caption).foregroundStyle(.secondary).help("Uses the internet") }
                    if kind.isInteractive { Image(systemName: "hand.tap").font(.caption).foregroundStyle(.secondary).help("Click it on the dock") }
                }
                Text(kind.blurb).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(docks) { dock in Button("Add to \(dock.name)") { add(dock.id) } }
                if docks.isEmpty { Button("Add to a New Dock") { add(nil) } }
            } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(12)
        .glassCard(radius: 18)
    }
}
