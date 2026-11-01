import Foundation
import Combine
import UniformTypeIdentifiers
import AppKit

/// Stores profiles and applies them. Capturing reads the live system Dock,
/// which shells out, so capture is asynchronous; applying is likewise
/// asynchronous because it may restart the Dock.
final class DockProfileStore: ObservableObject {
    @Published private(set) var profiles: [DockProfile] { didSet { save() } }
    /// The profile most recently applied, for a checkmark in the menu. This
    /// tracks what was last *applied*, not whether the current setup still
    /// matches it — editing a dock afterwards leaves the mark in place. Making
    /// it mean "still matches" would require diffing the whole setup against
    /// every profile on each keystroke, for a checkmark.
    @Published var activeProfileID: UUID? { didSet { saveActive() } }

    private static let profilesKey = "dockProfiles"
    private static let activeKey = "dockProfiles.active"

    private unowned let dockStore: SecondaryDockStore
    private unowned let themeStore: ThemeStore

    init(dockStore: SecondaryDockStore, themeStore: ThemeStore) {
        self.dockStore = dockStore
        self.themeStore = themeStore

        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([DockProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = []
        }

        if let string = UserDefaults.standard.string(forKey: Self.activeKey) {
            activeProfileID = UUID(uuidString: string)
        }
    }

    // MARK: - Capture

    func capture(named name: String, includeSystemDock: Bool, completion: @escaping (DockProfile) -> Void) {
        let docks = dockStore.docks
        let theme = themeStore.active

        // Reading `com.apple.dock` shells out to `defaults` and blocks, so it
        // never happens on the main thread — the same rule the settings screen
        // follows.
        DispatchQueue.global(qos: .userInitiated).async {
            let settings = includeSystemDock
                ? DockProfile.SystemDockSettings(DockDefaultsManager.loadCurrentSettings())
                : DockProfile.SystemDockSettings()

            let profile = DockProfile(
                name: name,
                includesSystemDock: includeSystemDock,
                systemDock: settings,
                docks: docks,
                theme: theme
            )

            DispatchQueue.main.async {
                self.profiles.append(profile)
                self.activeProfileID = profile.id
                completion(profile)
            }
        }
    }

    // MARK: - Apply

    func apply(_ profile: DockProfile, completion: @escaping () -> Void = {}) {
        // Custom docks and the theme are applied immediately — they're just
        // this app's own state and take effect without touching the system.
        themeStore.apply(profile.theme)
        dockStore.replaceAll(with: profile.docks)
        activeProfileID = profile.id

        guard profile.includesSystemDock else {
            completion()
            return
        }

        let settings = profile.systemDock.settings
        DispatchQueue.global(qos: .userInitiated).async {
            DockDefaultsManager.apply(settings)
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Editing

    func rename(_ profile: DockProfile, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].name = name
    }

    func delete(_ profile: DockProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = nil }
    }

    /// Overwrites a profile with the current setup, so "I tweaked this layout
    /// and want to keep it" doesn't require deleting and recapturing.
    func updateFromCurrentState(_ profile: DockProfile, completion: @escaping () -> Void = {}) {
        let docks = dockStore.docks
        let theme = themeStore.active
        let includeSystemDock = profile.includesSystemDock

        DispatchQueue.global(qos: .userInitiated).async {
            let settings = includeSystemDock
                ? DockProfile.SystemDockSettings(DockDefaultsManager.loadCurrentSettings())
                : profile.systemDock

            DispatchQueue.main.async {
                guard let index = self.profiles.firstIndex(where: { $0.id == profile.id }) else {
                    completion()
                    return
                }
                self.profiles[index].docks = docks
                self.profiles[index].theme = theme
                self.profiles[index].systemDock = settings
                self.activeProfileID = profile.id
                completion()
            }
        }
    }

    // MARK: - Import / export

    /// Profiles are portable: exporting one produces a plain JSON file that can
    /// be shared between Macs, which is also the only backup this app has.
    func export(_ profile: DockProfile, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: url, options: .atomic)
    }

    @discardableResult
    func importProfile(from url: URL) throws -> DockProfile {
        // A profile is a few kilobytes; anything vastly larger is not one.
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 2 * 1024 * 1024 else { throw ImportError.badSize }
        let data = try Data(contentsOf: url)
        var profile = try JSONDecoder().decode(DockProfile.self, from: data)
        profile.sanitizeAsImport()
        // A fresh identity so importing the same file twice yields two
        // profiles rather than one silently overwriting the other.
        profile.id = UUID()
        if profiles.contains(where: { $0.name == profile.name }) {
            profile.name += " (Imported)"
        }
        profiles.append(profile)
        return profile
    }

    enum ImportError: LocalizedError {
        case badSize
        var errorDescription: String? { "That file is empty or too large to be a Dawck profile." }
    }

    /// Replaces every profile at once, for restoring a backup.
    func replaceAll(with profiles: [DockProfile]) {
        self.profiles = profiles
        if let active = activeProfileID, !profiles.contains(where: { $0.id == active }) { activeProfileID = nil }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: Self.profilesKey)
    }

    private func saveActive() {
        UserDefaults.standard.set(activeProfileID?.uuidString, forKey: Self.activeKey)
    }
}
