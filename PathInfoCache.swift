import Foundation

/// Caches the two filesystem facts the dock views need per tile: whether the
/// target still exists, and what bundle identifier an app has.
///
/// Both were being recomputed inside `body`. `FileManager.fileExists` is a stat
/// per tile, and `Bundle(url:)` parses an Info.plist off disk — and body runs on
/// every mouse-move frame while magnification is active. With ten tiles that was
/// hundreds of filesystem round-trips a second for answers that change roughly
/// never.
///
/// Entries expire on a short interval rather than living forever, so an app
/// deleted or installed while Dawck is running is still noticed — just on the
/// next refresh instead of instantly.
final class PathInfoCache {
    static let shared = PathInfoCache()

    private struct Entry {
        let exists: Bool
        let isFolder: Bool
        let bundleID: String?
        let sampledAt: Date
    }

    private let lifetime: TimeInterval = 10
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    private init() {}

    func exists(_ path: String) -> Bool {
        entry(for: path).exists
    }

    func bundleIdentifier(forAppAt path: String) -> String? {
        entry(for: path).bundleID
    }

    /// A real directory the user would browse — not an `.app` bundle, which is
    /// a directory on disk but a launchable thing to everyone.
    func isBrowsableFolder(_ path: String) -> Bool {
        entry(for: path).isFolder
    }

    /// Drops everything, for when the app knows the answers just changed —
    /// a tile's path being edited, for instance.
    func invalidate() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    private func entry(for path: String) -> Entry {
        lock.lock()
        if let cached = entries[path], Date().timeIntervalSince(cached.sampledAt) < lifetime {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Computed outside the lock: `Bundle(url:)` touches the disk, and
        // holding a lock across that would serialise every tile behind the
        // slowest one.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let isApp = (path as NSString).pathExtension.lowercased() == "app"
        let bundleID: String? = (exists && path.hasSuffix(".app"))
            ? Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
            : nil
        let fresh = Entry(exists: exists, isFolder: exists && isDirectory.boolValue && !isApp,
                          bundleID: bundleID, sampledAt: Date())

        lock.lock()
        entries[path] = fresh
        lock.unlock()
        return fresh
    }
}
