import Foundation
import Combine
import CryptoKit

/// Snapshots of everything Dawck keeps — docks, themes and profiles — so a bad
/// afternoon of experimenting, or a profile switch gone wrong, is undoable.
///
/// A snapshot is written automatically at most once a day, and only when
/// something actually changed since the last one; the ten most recent are kept.
/// They live in Dawck's own Application Support folder, readable only by the
/// user, and restoring one is limited to files made there.
final class BackupManager: ObservableObject {
    static let shared = BackupManager()

    struct Info: Identifiable, Equatable {
        let url: URL
        let date: Date
        let isAutomatic: Bool
        var id: URL { url }
    }

    private struct Snapshot: Codable {
        var version = 1
        var docks: [SecondaryDock]
        var activeTheme: GlassTheme
        var savedThemes: [GlassTheme]
        var profiles: [DockProfile]
    }

    @Published private(set) var backups: [Info] = []

    private weak var dockStore: SecondaryDockStore?
    private weak var themeStore: ThemeStore?
    private weak var profileStore: DockProfileStore?
    private let keep = 10

    private init() {}

    func configure(dockStore: SecondaryDockStore, themeStore: ThemeStore, profileStore: DockProfileStore) {
        self.dockStore = dockStore
        self.themeStore = themeStore
        self.profileStore = profileStore
        refreshList()
    }

    private var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        // Test and development builds keep their own folder, so their throwaway
        // data can never appear among — or be restored over — the real backups.
        return base.appendingPathComponent(SystemSafety.allowsSystemWrites ? "Dawck/Backups" : "Dawck-Development/Backups", isDirectory: true)
    }

    private func ensureFolder() -> URL? {
        guard let folder else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    func refreshList() {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            backups = []
            return
        }
        backups = files.filter { $0.pathExtension == "dawckbackup" }.compactMap { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return Info(url: url, date: date, isAutomatic: url.lastPathComponent.hasPrefix("auto-"))
        }.sorted { $0.date > $1.date }
    }

    private func currentSnapshotData() -> Data? {
        guard let dockStore, let themeStore, let profileStore else { return nil }
        let snapshot = Snapshot(docks: dockStore.docks, activeTheme: themeStore.active, savedThemes: themeStore.saved, profiles: profileStore.profiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snapshot)
    }

    /// Writes a snapshot. `automatic` snapshots are skipped when nothing changed
    /// since the newest one or when one was already made in the last day.
    @discardableResult
    func backUp(automatic: Bool) -> Bool {
        guard let data = currentSnapshotData(), let folder = ensureFolder() else { return false }
        if automatic {
            if let newest = backups.first, Date().timeIntervalSince(newest.date) < 24 * 3600 { return false }
            if let newest = backups.first, let previous = try? Data(contentsOf: newest.url),
               SHA256.hash(data: previous) == SHA256.hash(data: data) { return false }
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let name = "\(automatic ? "auto" : "manual")-\(stamp.string(from: Date())).dawckbackup"
        let url = folder.appendingPathComponent(name)
        do {
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { return false }
        refreshList()
        prune()
        return true
    }

    private func prune() {
        // Manual backups are the user's own choice and are never pruned.
        let automatic = backups.filter(\.isAutomatic)
        for old in automatic.dropFirst(keep) { try? FileManager.default.removeItem(at: old.url) }
        refreshList()
    }

    enum RestoreError: LocalizedError {
        case notABackup, unreadable
        var errorDescription: String? {
            switch self {
            case .notABackup: return "That isn't one of Dawck's own backups."
            case .unreadable: return "That backup couldn't be read."
            }
        }
    }

    /// Restores a snapshot made by this app. The current state is backed up
    /// first, so a restore can itself be undone.
    func restore(_ info: Info) throws {
        guard let folder, info.url.standardizedFileURL.deletingLastPathComponent() == folder.standardizedFileURL,
              info.url.pathExtension == "dawckbackup" else { throw RestoreError.notABackup }
        guard let size = try? info.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 16 * 1024 * 1024,
              let data = try? Data(contentsOf: info.url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            throw RestoreError.unreadable
        }
        backUp(automatic: false)
        dockStore?.replaceAll(with: snapshot.docks.map { var d = $0; d.sanitize(); return d })
        themeStore?.apply(snapshot.activeTheme)
        themeStore?.saved = snapshot.savedThemes
        profileStore?.replaceAll(with: snapshot.profiles)
    }

    func delete(_ info: Info) {
        try? FileManager.default.removeItem(at: info.url)
        refreshList()
    }
}
