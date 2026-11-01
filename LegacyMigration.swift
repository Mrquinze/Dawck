import Foundation

/// Carries settings across the DockCraft -> Dawck rename.
///
/// The rename changed the bundle identifier, and a macOS app's `UserDefaults`
/// live in a domain named after that identifier — so without this, an existing
/// DockCraft user launches Dawck and finds every dock they had configured
/// simply gone. The stored *shape* is unchanged; only the domain moved.
///
/// Runs exactly once, guarded both by a flag in the new domain and by the
/// one-shot semantics of a `static let`, so it can never overwrite settings the
/// user has since changed in Dawck.
enum LegacyMigration {
    private static let legacyDomain = "com.matanlevi.DockCraft"
    private static let completionFlag = "migratedFromDockCraft"

    /// Keys whose stored representation is identical in both versions.
    /// `secondaryDocks` is JSON whose 1.x fields (`displayID`, `autohideEnabled`)
    /// the current decoder still understands and upgrades in place.
    private static let migratedKeys = [
        SecondaryDockStore.defaultsKey,
        AppPresentationDefaultsKey.mode
    ]

    /// Swift guarantees a `static let` initializer runs at most once and is
    /// thread-safe, which makes this correct no matter which store happens to
    /// be constructed first.
    private static let performed: Void = migrate()

    static func ensure() { _ = performed }

    private static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: completionFlag) else { return }

        // The flag is set even when there's nothing to copy, so a fresh install
        // doesn't re-probe the old domain on every launch.
        defer { defaults.set(true, forKey: completionFlag) }

        guard let legacy = UserDefaults(suiteName: legacyDomain) else { return }

        var migrated: [String] = []
        for key in migratedKeys {
            // Anything already present in the new domain wins — the user has
            // been using Dawck, and their newer choice must not be reverted.
            guard defaults.object(forKey: key) == nil else { continue }
            guard let value = legacy.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            migrated.append(key)
        }

        if !migrated.isEmpty {
            NSLog("Dawck: migrated \(migrated.joined(separator: ", ")) from DockCraft.")
        }
    }
}
