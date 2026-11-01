import AppKit

/// Caches icons keyed by path and pixel size.
///
/// `NSWorkspace.icon(forFile:)` hits the filesystem and the icon services
/// daemon. The dock views ask for an icon during *every* body evaluation, and
/// magnification re-evaluates those bodies on every mouse-move frame — so an
/// uncached lookup meant dozens of filesystem round-trips per second per dock.
/// That was the single biggest cost in the old rendering path.
final class IconProvider {
    static let shared = IconProvider()

    private let cache = NSCache<NSString, NSImage>()
    private var observer: NSObjectProtocol?

    private init() {
        cache.countLimit = 256
        // An app updating in place keeps its path but changes its icon, so the
        // cache is dropped whenever the set of installed apps changes.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    /// Icons are rasterised at a fixed set of sizes rather than at the exact
    /// magnified size, which changes continuously during a hover. Rounding up
    /// to the next bucket keeps the cache from growing a new entry per frame,
    /// and the view scales the result — no visible difference, since the bucket
    /// is never smaller than the requested size.
    private static let sizeBuckets: [CGFloat] = [32, 64, 128, 256, 512]

    private static func bucket(for size: CGFloat) -> CGFloat {
        sizeBuckets.first { $0 >= size } ?? sizeBuckets[sizeBuckets.count - 1]
    }

    func icon(forPath path: String, size: CGFloat) -> NSImage {
        let bucket = Self.bucket(for: size)
        let key = "\(path)@\(Int(bucket))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: bucket, height: bucket)
        cache.setObject(image, forKey: key)
        return image
    }

    /// A user-supplied replacement icon. Falls back to the filesystem icon if
    /// the override file has since gone missing, so a deleted custom icon
    /// degrades to the normal one instead of to a blank tile.
    func customIcon(atPath customPath: String, fallbackPath: String, size: CGFloat) -> NSImage {
        let bucket = Self.bucket(for: size)
        let key = "custom:\(customPath)@\(Int(bucket))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let image = NSImage(contentsOfFile: customPath) else {
            return icon(forPath: fallbackPath, size: size)
        }
        image.size = NSSize(width: bucket, height: bucket)
        cache.setObject(image, forKey: key)
        return image
    }

    func icon(for item: DockItem, size: CGFloat) -> NSImage? {
        guard item.kind == .file else { return nil }
        if let customIconPath = item.customIconPath, !customIconPath.isEmpty {
            return customIcon(atPath: customIconPath, fallbackPath: item.path, size: size)
        }
        return icon(forPath: item.path, size: size)
    }
}
