import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var dockStore: SecondaryDockStore
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var profileStore: DockProfileStore

    @AppStorage(SettingsWindowController.paneKey) private var selectionRaw = Pane.docks.rawValue

    private var selection: Pane {
        get { Pane(rawValue: selectionRaw) ?? .docks }
        nonmutating set { selectionRaw = newValue.rawValue }
    }

    enum Pane: String, CaseIterable, Identifiable {
        case docks, theme, widgets, menuBar, profiles, mainDock, dockContents, hotCorners, general
        var id: String { rawValue }

        var label: String {
            switch self {
            case .docks: return "Docks"
            case .theme: return "Theme"
            case .widgets: return "Widgets"
            case .menuBar: return "Menu Bar"
            case .profiles: return "Profiles"
            case .mainDock: return "System Dock"
            case .dockContents: return "Dock Contents"
            case .hotCorners: return "Hot Corners"
            case .general: return "General"
            }
        }

        var symbol: String {
            switch self {
            case .docks: return "rectangle.stack"
            case .theme: return "sparkles"
            case .widgets: return "square.grid.2x2"
            case .menuBar: return "menubar.rectangle"
            case .profiles: return "person.crop.rectangle.stack"
            case .mainDock: return "dock.rectangle"
            case .dockContents: return "square.grid.3x1.below.line.grid.1x2"
            case .hotCorners: return "arrow.up.left.and.arrow.down.right"
            case .general: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { selection }, set: { selection = $0 ?? .docks })) { pane in
                Label(pane.label, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 172, ideal: 186, max: 220)
        } detail: {
            Group {
                switch selection {
                case .docks: DocksSettingsView()
                case .theme: ThemeSettingsView()
                case .widgets: WidgetGalleryView()
                case .menuBar: MenuBarSettingsView()
                case .profiles: ProfilesSettingsView()
                case .mainDock: MainDockSettingsView()
                case .dockContents: DockContentsView()
                case .hotCorners: HotCornersView()
                case .general: GeneralSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background { AmbientBackdrop() }
            .navigationTitle(selection.label)
        }
    }
}

#Preview {
    let themeStore = ThemeStore()
    let dockStore = SecondaryDockStore()
    return ContentView()
        .environmentObject(dockStore)
        .environmentObject(themeStore)
        .environmentObject(DockProfileStore(dockStore: dockStore, themeStore: themeStore))
        .frame(width: 900, height: 640)
}
