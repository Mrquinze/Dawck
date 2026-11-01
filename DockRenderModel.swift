import AppKit

/// One tile as the dock view sees it: the configured item plus whatever is live
/// about it right now.
struct TileModel: Equatable, Identifiable {
    var item: DockItem
    var isRunning = false
    var widget: WidgetSnapshot?
    /// Set while a launch is in flight, so the tile can bounce.
    var isLaunching = false
    /// Trash: whether anything is in it.
    var isFull = false

    var id: UUID { item.id }
}

/// Everything the dock view needs to draw, as one value. The view diffs it
/// against the previous one and touches only the layers that changed.
struct DockRenderModel: Equatable {
    var dock: SecondaryDock
    var theme: GlassTheme
    var tiles: [TileModel]
    var isEditing = false
    var systemIsDark = true
    /// The dock's contents come from somewhere else (a mirror or a filter), so
    /// the tiles can't be reordered, dropped on or removed here.
    var isDerived = false
}

/// What dropping the current drag would do.
enum DropIntent: Equatable {
    /// Open the dropped files with an app tile.
    case open(tile: UUID)
    /// Move or copy the files into a folder tile.
    case moveInto(tile: UUID)
    /// Park them in a tray.
    case stash(tile: UUID)
    /// Throw them in the Trash.
    case trash
    /// Pin them to the dock at this position.
    case pin(index: Int)
    /// Reorder an existing tile to this position.
    case reorder(tile: UUID, index: Int)
}

protocol DockContentDelegate: AnyObject {
    func dockContent(_ view: DockContentView, didClick tile: TileModel, rect: NSRect)
    func dockContent(_ view: DockContentView, menuFor tile: TileModel?, rect: NSRect) -> NSMenu?
    func dockContent(_ view: DockContentView, hover tile: TileModel?, screenRect: NSRect?)
    func dockContent(_ view: DockContentView, canAccept intent: DropIntent) -> Bool
    func dockContent(_ view: DockContentView, perform intent: DropIntent, urls: [URL], copy: Bool) -> Bool
    func dockContent(_ view: DockContentView, remove tile: UUID)
    func dockContentDidClickPill(_ view: DockContentView)
    func dockContent(_ view: DockContentView, scrolled tile: TileModel, delta: CGFloat)
}
