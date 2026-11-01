import AppKit
import Combine

/// Switches profiles automatically based on which app is in front — DockDoor's
/// "AppSense". Focus Xcode and your dev layout appears; focus Mail and it
/// doesn't.
///
/// Costs no permission: `NSWorkspace.didActivateApplicationNotification`
/// reports the frontmost app's bundle identifier to any app that asks.
struct AppSenseRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var bundleIdentifier: String
    var appName: String
    var profileID: UUID
    var isEnabled: Bool = true

    init(id: UUID = UUID(), bundleIdentifier: String, appName: String, profileID: UUID, isEnabled: Bool = true) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.profileID = profileID
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, bundleIdentifier, appName, profileID, isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? bundleIdentifier
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID) ?? UUID()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

final class AppSenseStore: ObservableObject {
    @Published var rules: [AppSenseRule] { didSet { save() } }
    /// Applies the profile named by `fallbackProfileID` when the frontmost app
    /// matches no rule. Off by default: silently reverting every time the user
    /// alt-tabs to something unlisted would be startling.
    @Published var usesFallback: Bool { didSet { save() } }
    @Published var fallbackProfileID: UUID? { didSet { save() } }
    @Published var isEnabled: Bool { didSet { save() } }

    private static let rulesKey = "appSenseRules"
    private static let enabledKey = "appSenseEnabled"
    private static let fallbackKey = "appSenseFallback"
    private static let usesFallbackKey = "appSenseUsesFallback"

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.rulesKey),
           let decoded = try? JSONDecoder().decode([AppSenseRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        usesFallback = defaults.bool(forKey: Self.usesFallbackKey)
        fallbackProfileID = defaults.string(forKey: Self.fallbackKey).flatMap(UUID.init(uuidString:))
    }

    func rule(for bundleID: String) -> AppSenseRule? {
        rules.first { $0.isEnabled && $0.bundleIdentifier == bundleID }
    }

    func add(bundleIdentifier: String, appName: String, profileID: UUID) {
        // One rule per app: a second rule for the same bundle id could never
        // fire, since lookup takes the first match.
        guard !rules.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        rules.append(AppSenseRule(bundleIdentifier: bundleIdentifier, appName: appName, profileID: profileID))
    }

    func remove(_ rule: AppSenseRule) {
        rules.removeAll { $0.id == rule.id }
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: Self.rulesKey)
        }
        defaults.set(isEnabled, forKey: Self.enabledKey)
        defaults.set(usesFallback, forKey: Self.usesFallbackKey)
        defaults.set(fallbackProfileID?.uuidString, forKey: Self.fallbackKey)
    }
}

/// Watches the frontmost app and applies the matching profile.
final class AppSenseManager {
    private let store: AppSenseStore
    private let profileStore: DockProfileStore
    private var observer: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []
    /// The profile currently applied by AppSense, so re-activating the same app
    /// doesn't reapply — applying a profile that includes system Dock settings
    /// restarts the Dock, and doing that on every Cmd-Tab would be unusable.
    private var lastAppliedProfileID: UUID?

    init(store: AppSenseStore, profileStore: DockProfileStore) {
        self.store = store
        self.profileStore = profileStore

        store.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                enabled ? self?.startObserving() : self?.stopObserving()
            }
            .store(in: &cancellables)

        if store.isEnabled { startObserving() }
    }

    deinit { stopObserving() }

    private func startObserving() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.handleActivation(of: app)
        }
        // Applies immediately for whatever is already frontmost, so enabling
        // AppSense takes effect without waiting for the next app switch.
        if let front = NSWorkspace.shared.frontmostApplication {
            handleActivation(of: front)
        }
    }

    private func stopObserving() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
        lastAppliedProfileID = nil
    }

    private func handleActivation(of app: NSRunningApplication) {
        // Dawck activating its own window must not count as an app switch, or
        // opening Settings would trigger a profile change.
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        guard let bundleID = app.bundleIdentifier else { return }

        let targetID: UUID?
        if let rule = store.rule(for: bundleID) {
            targetID = rule.profileID
        } else if store.usesFallback {
            targetID = store.fallbackProfileID
        } else {
            targetID = nil
        }

        guard let targetID, targetID != lastAppliedProfileID else { return }
        guard let profile = profileStore.profiles.first(where: { $0.id == targetID }) else { return }

        lastAppliedProfileID = targetID
        profileStore.apply(profile)
    }
}
