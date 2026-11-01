import Foundation
import Combine

/// Persists the user's themes. The app always has exactly one *active*
/// theme plus any number of saved ones; individual docks may override the
/// active theme with a saved theme of their own.
final class ThemeStore: ObservableObject {
    @Published var active: GlassTheme { didSet { scheduleSave() } }
    @Published var saved: [GlassTheme] { didSet { scheduleSave() } }

    private static let activeKey = "glassTheme.active"
    private static let savedKey = "glassTheme.saved"
    private let writer = DebouncedWriter()

    init() {
        LegacyMigration.ensure()
        let decoder = JSONDecoder()

        if let data = UserDefaults.standard.data(forKey: Self.activeKey),
           let theme = try? decoder.decode(GlassTheme.self, from: data) {
            active = theme
        } else {
            active = GlassTheme.presets[0]
        }

        if let data = UserDefaults.standard.data(forKey: Self.savedKey),
           let themes = try? decoder.decode([GlassTheme].self, from: data) {
            saved = themes
        } else {
            saved = []
        }
    }

    /// Resolves the theme a given dock should render with: its own override if
    /// it names one that still exists, otherwise the active theme. A dangling
    /// override (theme deleted while a dock still points at it) falls back
    /// rather than leaving that dock unrendered.
    func theme(for overrideID: UUID?) -> GlassTheme {
        guard let overrideID else { return active }
        return saved.first { $0.id == overrideID } ?? active
    }

    func saveCurrentAsNew(named name: String) {
        var copy = active.asEditableCopy()
        copy.name = name
        saved.append(copy)
    }

    func delete(_ theme: GlassTheme) {
        saved.removeAll { $0.id == theme.id }
    }

    func apply(_ theme: GlassTheme) {
        // Keeps the incoming identity so a dock overriding this theme keeps
        // pointing at the same one after it's made active.
        active = theme
    }

    func flush() { writer.flush() }

    private func scheduleSave() {
        writer.schedule { [active, saved] in
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(active) {
                UserDefaults.standard.set(data, forKey: Self.activeKey)
            }
            if let data = try? encoder.encode(saved) {
                UserDefaults.standard.set(data, forKey: Self.savedKey)
            }
        }
    }
}
