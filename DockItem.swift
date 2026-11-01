import Foundation
import AppKit

/// What a tile in a dock actually *is*. Stored as a flat string rather than an
/// enum with associated values so that a dock saved by a build that knows more
/// kinds than this one still decodes — the unknown kind falls back to
/// `.separator`, which renders as an inert gap instead of failing the whole
/// dock's decode and taking every other tile with it.
enum DockItemKind: String, Codable, CaseIterable, Identifiable {
    /// An app, folder, or document on disk.
    case file
    /// A deep link, Shortcut, script, or command — an ExtraBar-style action.
    case action
    /// A live readout: clock, CPU, memory, battery, disk.
    case widget
    /// A fixed gap, the secondary-dock equivalent of a Dock spacer tile.
    case separator
    /// A drop shelf: drag files in to stage them, drag them back out later.
    case tray
    /// Several apps folded behind one tile, fanning out on click.
    case group
    /// The Trash: open it, drop things on it, empty it.
    case trash

    var id: String { rawValue }

    var label: String {
        switch self {
        case .file: return "App or Folder"
        case .action: return "Action"
        case .widget: return "Widget"
        case .separator: return "Spacer"
        case .tray: return "File Tray"
        case .group: return "App Group"
        case .trash: return "Trash"
        }
    }

    var symbol: String {
        switch self {
        case .file: return "app.dashed"
        case .action: return "bolt.horizontal"
        case .widget: return "gauge.with.dots.needle.33percent"
        case .separator: return "space"
        case .tray: return "tray.full"
        case .group: return "square.stack.3d.up"
        case .trash: return "trash"
        }
    }
}

/// How an action tile fires. Every one of these is a user-authored local
/// automation; none of them requires a system permission prompt on its own,
/// though the *target* may ask for one the first time (Shortcuts and
/// AppleScript can both trigger Automation consent for the app they drive).
enum DockActionType: String, Codable, CaseIterable, Identifiable {
    /// Any URL, including app deep links: `spotify:playlist:…`, `slack://channel?…`,
    /// `raycast://…`, `things:///show?id=…`, plain `https://…`.
    case url
    /// Runs a named shortcut through `/usr/bin/shortcuts`.
    case shortcut
    /// Runs a command line under the login shell.
    case shell
    /// Runs an AppleScript source snippet.
    case appleScript

    var id: String { rawValue }

    var label: String {
        switch self {
        case .url: return "Deep Link / URL"
        case .shortcut: return "Apple Shortcut"
        case .shell: return "Shell Command"
        case .appleScript: return "AppleScript"
        }
    }

    var placeholder: String {
        switch self {
        case .url: return "raycast://extensions/raycast/raycast/search"
        case .shortcut: return "Start Focus Session"
        case .shell: return "open -a Terminal ~/Projects"
        case .appleScript: return "tell application \"Music\" to playpause"
        }
    }

    /// The fallback glyph when the user hasn't picked one.
    var defaultSymbol: String {
        switch self {
        case .url: return "link"
        case .shortcut: return "square.stack.3d.up"
        case .shell: return "terminal"
        case .appleScript: return "applescript"
        }
    }
}

enum FolderLayout: String, Codable, CaseIterable, Identifiable {
    case grid, list, fan
    var id: String { rawValue }
    var label: String {
        switch self {
        case .grid: return "Grid"
        case .list: return "List"
        case .fan: return "Fan"
        }
    }
    var symbol: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .fan: return "rectangle.stack"
        }
    }
}

enum FolderSort: String, Codable, CaseIterable, Identifiable {
    case name, dateAdded, dateModified, kind
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .kind: return "Kind"
        }
    }
}

/// How a pinned folder presents its contents, set per folder.
struct FolderOptions: Codable, Equatable {
    var layout: FolderLayout = .grid
    var sort: FolderSort = .name
    var showsHidden = false
    var showsPreviews = true

    init() {}

    private enum CodingKeys: String, CodingKey { case layout, sort, showsHidden, showsPreviews }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layout = c.value(.layout, FolderLayout.grid)
        sort = c.value(.sort, FolderSort.name)
        showsHidden = c.value(.showsHidden, false)
        showsPreviews = c.value(.showsPreviews, true)
    }
}

/// One tile. All payload fields are stored side by side rather than in a
/// discriminated union, so switching a tile's kind in the editor keeps whatever
/// was already typed into the other fields — change kind by mistake, change it
/// back, nothing is lost.
struct DockItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: DockItemKind = .file

    // file
    var path: String = ""

    // action
    var actionType: DockActionType = .url
    var actionPayload: String = ""
    /// SF Symbol name shown for an action tile.
    var actionSymbol: String = ""
    /// Actions that run code or open arbitrary URLs arrive disabled when they
    /// come from an imported profile, until the user has read and approved
    /// them. Tiles the user made themselves are trusted from the start.
    var isTrusted: Bool = true

    // widget
    var widget: DockWidgetKind = .clock
    var widgetOptions = WidgetOptions()

    // folder
    var folderOptions = FolderOptions()

    /// Paths folded behind a `.group` tile, and the staged files held by a
    /// `.tray` tile. Both are plain path lists, so a tray survives relaunch and
    /// a group is editable in the same UI as anything else.
    var memberPaths: [String] = []

    /// Overrides the icon a `.file` tile would otherwise inherit from the
    /// filesystem — XtraDock's "replace app icons with ones that fit better".
    var customIconPath: String?
    /// Overrides the displayed name in tooltips and menus.
    var customName: String?

    init(
        id: UUID = UUID(),
        kind: DockItemKind = .file,
        path: String = "",
        actionType: DockActionType = .url,
        actionPayload: String = "",
        actionSymbol: String = "",
        widget: DockWidgetKind = .clock,
        memberPaths: [String] = [],
        customIconPath: String? = nil,
        customName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.actionType = actionType
        self.actionPayload = actionPayload
        self.actionSymbol = actionSymbol
        self.widget = widget
        self.memberPaths = memberPaths
        self.customIconPath = customIconPath
        self.customName = customName
    }

    /// Convenience for the common case — dropping a file onto a dock.
    init(path: String) {
        self.init(kind: .file, path: path)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, path, actionType, actionPayload, actionSymbol, isTrusted,
             widget, widgetOptions, folderOptions, memberPaths, customIconPath, customName
    }

    /// Every field falls back on its own, so one value this build can't read
    /// (a tile kind from a newer version, a mangled string in an imported
    /// profile) costs that value, not the tile — and not the dock around it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        kind = c.value(.kind, DockItemKind.separator)
        path = String(c.value(.path, "").prefix(4096))
        actionType = c.value(.actionType, DockActionType.url)
        actionPayload = String(c.value(.actionPayload, "").prefix(16_384))
        actionSymbol = String(c.value(.actionSymbol, "").prefix(128))
        isTrusted = c.value(.isTrusted, true)
        widget = c.value(.widget, DockWidgetKind.clock)
        widgetOptions = c.value(.widgetOptions, WidgetOptions())
        folderOptions = c.value(.folderOptions, FolderOptions())
        memberPaths = Array(c.value(.memberPaths, [String]()).prefix(500)).map { String($0.prefix(4096)) }
        customIconPath = (try? c.decodeIfPresent(String.self, forKey: .customIconPath)).map { String($0.prefix(4096)) }
        customName = (try? c.decodeIfPresent(String.self, forKey: .customName)).map { String($0.prefix(200)) }
    }

    // MARK: - Derived

    var url: URL { URL(fileURLWithPath: path) }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        switch kind {
        case .file:
            return path.isEmpty ? "Missing Item" : FileManager.default.displayName(atPath: path)
        case .action:
            return actionPayload.isEmpty ? actionType.label : String(actionPayload.prefix(60))
        case .widget:
            return widget.label
        case .separator:
            return "Spacer"
        case .tray:
            return memberPaths.isEmpty ? "File Tray" : "File Tray (\(memberPaths.count))"
        case .group:
            return memberPaths.isEmpty ? "App Group" : "\(memberPaths.count) apps"
        case .trash:
            return "Trash"
        }
    }

    /// True only for real directories — a `.app` bundle is a directory on disk
    /// but must behave as a launchable item, not as a folder to browse.
    var isDirectory: Bool {
        guard kind == .file else { return false }
        return PathInfoCache.shared.isBrowsableFolder(path)
    }

    /// A `.file` tile whose target has since been moved or deleted. Shown
    /// dimmed rather than silently dropped, so the user can see what broke.
    /// Cached, because it is read when tiles are laid out.
    var isMissing: Bool {
        kind == .file && !PathInfoCache.shared.exists(path)
    }

    var symbolName: String {
        switch kind {
        case .action: return actionSymbol.isEmpty ? actionType.defaultSymbol : actionSymbol
        case .widget: return widget.symbol
        default: return kind.symbol
        }
    }

    /// The bundle identifier a `.file` tile launches, when it's an app — used
    /// to match this tile against the running-application list so it can show a
    /// running indicator and activate instead of relaunching.
    var bundleIdentifier: String? {
        guard kind == .file, path.hasSuffix(".app") else { return nil }
        return PathInfoCache.shared.bundleIdentifier(forAppAt: path)
    }

    /// Whether running this tile executes code the user hasn't approved.
    var needsApproval: Bool { kind == .action && !isTrusted }
}
