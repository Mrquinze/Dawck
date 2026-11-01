import Foundation
import AppKit
import Combine

/// Reads the real Dock's contents so a secondary dock can mirror it — the
/// "Live Dock" idea: put a copy of your actual Dock on a second display.
///
/// The Dock stores its tiles in `com.apple.dock`'s `persistent-apps` /
/// `persistent-others` arrays. There is no API for this, so the preference file
/// is read directly. It is only ever read, which keeps mirroring strictly
/// observational — it can't corrupt the user's real Dock.
///
/// The file is watched rather than polled: the Dock rewrites it when a tile is
/// added, moved or removed, and a vnode watch costs nothing in between. A slow
/// backstop poll remains for the cases a file watch can miss (the file being
/// replaced by a sync).
final class SystemDockReader: ObservableObject {
    static let shared = SystemDockReader()

    @Published private(set) var items: [DockItem] = []

    private var subscribers = 0
    private var watch: DispatchSourceFileSystemObject?
    private var backstop: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.matanlevi.Dawck.dockreader", qos: .utility)

    private var preferencesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.apple.dock.plist")
    }

    private init() {}

    func start() {
        subscribers += 1
        guard backstop == nil else { return }
        refresh()
        armWatch()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        backstop = timer
    }

    func stop() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        watch?.cancel()
        watch = nil
        backstop?.cancel()
        backstop = nil
        debounce?.cancel()
    }

    /// Watches the preference file. cfprefsd replaces the file atomically, so a
    /// delete or rename means "look again, and re-attach to the new file".
    private func armWatch() {
        watch?.cancel()
        let descriptor = open(preferencesURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename, .extend], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            let replaced = source?.data.contains(.delete) == true || source?.data.contains(.rename) == true
            self.scheduleRefresh()
            if replaced { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.armWatch() } }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watch = source
    }

    /// The Dock writes several times in a row while it settles; wait for quiet.
    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func refresh() {
        queue.async {
            let paths = Self.readDockPaths()
            DispatchQueue.main.async {
                // Compared by path rather than by `DockItem`, whose `id` is a
                // fresh UUID on every read and would never compare equal.
                guard self.items.map(\.path) != paths else { return }
                self.items = paths.map { DockItem(path: $0) }
            }
        }
    }

    /// Pulls file paths out of both persistent arrays, in Dock order.
    /// Spacer tiles carry no file URL and drop out naturally.
    private static func readDockPaths() -> [String] {
        var paths: [String] = []
        for key in ["persistent-apps", "persistent-others"] {
            guard let tiles = DockPrefs.raw(key) as? [[String: Any]] else { continue }
            for tile in tiles {
                guard let data = tile["tile-data"] as? [String: Any],
                      let fileData = data["file-data"] as? [String: Any],
                      let urlString = fileData["_CFURLString"] as? String else { continue }
                // `_CFURLStringType` 15 means the string is a full file URL;
                // 0 means it's already a bare POSIX path.
                let type = fileData["_CFURLStringType"] as? Int ?? 15
                let path = type == 15 ? URL(string: urlString)?.path : urlString
                if let path, !path.isEmpty { paths.append(path) }
            }
        }
        return Array(paths.prefix(300))
    }
}
