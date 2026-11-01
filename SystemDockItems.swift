import Foundation
import AppKit

/// Reads and rewrites the real Dock's contents — the apps, folders, and spacer
/// tiles in `com.apple.dock`'s `persistent-apps` and `persistent-others` arrays.
///
/// There is no public API for this. The Dock keeps its tiles as plists in its
/// own preference domain, and every tool that reorders the Dock does so by
/// rewriting those arrays and restarting the Dock. `CFPreferences` is used
/// rather than shelling out to `/usr/bin/defaults`: the tile entries are nested
/// dictionaries, and expressing those on a `defaults write` command line means
/// serialising a plist into a shell argument, which breaks on the first label
/// containing a quote.
///
/// The Dock caches its tiles in memory and rewrites the plist when it exits, so
/// it must be restarted after a write — otherwise the running Dock overwrites
/// the change on its next flush.
enum SystemDockItems {
    private static let domain = "com.apple.dock" as CFString

    enum Section: String, CaseIterable, Identifiable {
        case apps = "persistent-apps"
        case others = "persistent-others"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .apps: return "Apps"
            case .others: return "Folders & Files"
            }
        }
    }

    /// How a folder tile in the "others" section presents itself.
    enum FolderDisplay: Int, CaseIterable, Identifiable {
        case stack = 0, folder = 1
        var id: Int { rawValue }
        var label: String { self == .stack ? "Stack" : "Folder" }
    }

    enum FolderView: Int, CaseIterable, Identifiable {
        case automatic = 0, fan = 1, grid = 2, list = 3
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .fan: return "Fan"
            case .grid: return "Grid"
            case .list: return "List"
            }
        }
    }

    struct Tile: Identifiable, Equatable {
        /// Index within its section — the Dock has no stable per-tile id, so
        /// position is the identity. Regenerated on every read.
        let id: String
        var section: Section
        var label: String
        var path: String?
        var isSpacer: Bool
        var isSmallSpacer: Bool
        var folderDisplay: FolderDisplay
        var folderView: FolderView

        var displayName: String {
            if isSpacer { return isSmallSpacer ? "Small Spacer" : "Spacer" }
            return label.isEmpty ? (path.map { ($0 as NSString).lastPathComponent } ?? "Untitled") : label
        }

        var icon: NSImage? {
            guard let path, !isSpacer else { return nil }
            return IconProvider.shared.icon(forPath: path, size: 32)
        }

        var isMissing: Bool {
            guard let path, !isSpacer else { return false }
            return !PathInfoCache.shared.exists(path)
        }
    }

    // MARK: - Reading

    static func read(_ section: Section) -> [Tile] {
        guard let raw = CFPreferencesCopyAppValue(section.rawValue as CFString, domain) as? [[String: Any]] else {
            return []
        }

        return raw.enumerated().map { index, entry in
            let tileType = entry["tile-type"] as? String ?? "file-tile"
            let data = entry["tile-data"] as? [String: Any] ?? [:]
            let fileData = data["file-data"] as? [String: Any]

            return Tile(
                id: "\(section.rawValue)-\(index)",
                section: section,
                label: data["file-label"] as? String ?? "",
                path: fileData.flatMap(path(fromFileData:)),
                isSpacer: tileType.hasSuffix("spacer-tile"),
                isSmallSpacer: tileType == "small-spacer-tile",
                folderDisplay: FolderDisplay(rawValue: data["displayas"] as? Int ?? 0) ?? .stack,
                folderView: FolderView(rawValue: data["showas"] as? Int ?? 0) ?? .automatic
            )
        }
    }

    /// `_CFURLStringType` 15 means the string is a full file URL; 0 means it's
    /// already a bare POSIX path. Treating one as the other yields paths like
    /// "/Applications/file:///Applications".
    private static func path(fromFileData fileData: [String: Any]) -> String? {
        guard let string = fileData["_CFURLString"] as? String else { return nil }
        let type = fileData["_CFURLStringType"] as? Int ?? 15
        let path = type == 15 ? URL(string: string)?.path : string
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    // MARK: - Writing

    /// Rewrites a section from a list of tiles and restarts the Dock.
    static func write(_ tiles: [Tile], to section: Section, restart: Bool = true) {
        let entries: [[String: Any]] = tiles.map(entry(for:))
        DockPrefs.set(section.rawValue, entries)
        DockPrefs.commit()
        if restart { DockDefaultsManager.restartDock() }
    }

    private static func entry(for tile: Tile) -> [String: Any] {
        if tile.isSpacer {
            return [
                "tile-type": tile.isSmallSpacer ? "small-spacer-tile" : "spacer-tile",
                "tile-data": [String: Any]()
            ]
        }

        guard let path = tile.path else {
            return ["tile-type": "spacer-tile", "tile-data": [String: Any]()]
        }

        let url = URL(fileURLWithPath: path)
        var data: [String: Any] = [
            "file-data": [
                "_CFURLString": url.absoluteString,
                "_CFURLStringType": 15
            ],
            "file-label": tile.displayName
        ]

        if tile.section == .others {
            // Folder tiles carry their own presentation. Apps don't, and
            // writing these keys onto an app tile makes the Dock treat it as a
            // directory and render it as an empty stack.
            data["displayas"] = tile.folderDisplay.rawValue
            data["showas"] = tile.folderView.rawValue
            data["arrangement"] = 1
        }

        return [
            "tile-type": tile.section == .others ? "directory-tile" : "file-tile",
            "tile-data": data
        ]
    }

    // MARK: - Mutations

    static func move(in section: Section, from source: IndexSet, to destination: Int) {
        var tiles = read(section)
        tiles.move(fromOffsets: source, toOffset: destination)
        write(tiles, to: section)
    }

    static func remove(at offsets: IndexSet, from section: Section) {
        var tiles = read(section)
        tiles.remove(atOffsets: offsets)
        write(tiles, to: section)
    }

    static func add(paths: [String], to section: Section) {
        var tiles = read(section)
        for path in paths where !tiles.contains(where: { $0.path == path }) {
            tiles.append(Tile(
                id: UUID().uuidString,
                section: section,
                label: FileManager.default.displayName(atPath: path),
                path: path,
                isSpacer: false,
                isSmallSpacer: false,
                folderDisplay: .stack,
                folderView: .automatic
            ))
        }
        write(tiles, to: section)
    }

    static func addSpacer(small: Bool, to section: Section) {
        var tiles = read(section)
        tiles.append(Tile(
            id: UUID().uuidString,
            section: section,
            label: "",
            path: nil,
            isSpacer: true,
            isSmallSpacer: small,
            folderDisplay: .stack,
            folderView: .automatic
        ))
        write(tiles, to: section)
    }

    static func update(_ tile: Tile) {
        var tiles = read(tile.section)
        guard let index = tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        tiles[index] = tile
        write(tiles, to: tile.section)
    }

    /// Drops every tile whose target no longer exists. The Dock renders these
    /// as generic question-mark icons and offers no way to identify them in
    /// bulk.
    @discardableResult
    static func removeMissing() -> Int {
        var removed = 0
        for section in Section.allCases {
            let tiles = read(section)
            let kept = tiles.filter { !$0.isMissing }
            if kept.count != tiles.count {
                removed += tiles.count - kept.count
                write(kept, to: section, restart: false)
            }
        }
        if removed > 0 { DockDefaultsManager.restartDock() }
        return removed
    }
}
