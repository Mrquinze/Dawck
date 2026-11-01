import AppKit
import QuartzCore
import SwiftUI

/// What a tile needs, beyond its own item, to decide how to draw.
struct TileRenderContext: Equatable {
    var base: CGFloat
    var maxSize: CGFloat
    var scale: CGFloat
    var saturation: Double
    var tileShape: TileShape
    var backingOpacity: Double
    var darkForeground: Bool
    var darkScheme: Bool
    var indicatorStyle: IndicatorStyle
    var indicatorColor: CodableColor
    var dimsNonRunning: Bool
    var showsLabels: Bool
    var isEditing: Bool
    var accent: CodableColor
    /// Bumps once a day / minute so live Calendar and Clock icons redraw.
    var liveStamp: Int

    var foreground: NSColor { darkForeground ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 1, alpha: 1) }

    /// The bitmap is rendered at the largest size the tile reaches, so scaling
    /// it down at rest stays crisp and scaling it up never blurs.
    var pixels: Int {
        let raw = Double(max(maxSize, base) * scale)
        return min(max(Int((raw / 32).rounded(.up)) * 32, 64), 1024)
    }
}

/// The layers that make up one tile. Created once and only ever moved, scaled
/// and re-faded afterwards: hovering over a dock is a few hundred property
/// writes on existing layers, never a view update.
final class TileLayer {
    let id: UUID
    /// Carries the scale transform. Its anchor sits at the screen-edge side of
    /// the tile, so growing away from the edge is just a scale.
    let host = CALayer()
    private let backing = CALayer()
    private let icon = CALayer()
    private let glow = CALayer()
    private let ring = CAShapeLayer()
    /// Children of the dock's tile root rather than of `host`: they don't scale
    /// with the icon, so a magnified tile doesn't get a magnified dot.
    let indicator = CAShapeLayer()
    let label = CATextLayer()
    let badge = CALayer()
    let minus = CALayer()
    let missing = CALayer()

    private(set) var model: TileModel
    private var renderKey = ""
    private var glowKey = ""

    init(model: TileModel) {
        self.id = model.id
        self.model = model
        host.addSublayer(glow)
        host.addSublayer(backing)
        host.addSublayer(icon)
        host.addSublayer(ring)
        host.addSublayer(missing)
        for layer in [icon, glow, badge, minus, missing] {
            layer.contentsGravity = .resizeAspect
            layer.magnificationFilter = .linear
            layer.minificationFilter = .trilinear
        }
        glow.opacity = 0
        ring.fillColor = nil
        ring.opacity = 0
        label.alignmentMode = .center
        label.truncationMode = .middle
        label.isWrapped = false
        badge.isHidden = true
        minus.isHidden = true
        missing.isHidden = true
    }

    var layers: [CALayer] { [host, indicator, label, badge, minus] }

    /// The bitmap currently shown, for building drag images.
    var currentImage: CGImage? {
        guard let contents = icon.contents else { return nil }
        // swiftlint:disable:next force_cast
        return CFGetTypeID(contents as CFTypeRef) == CGImage.typeID ? (contents as! CGImage) : nil
    }

    // MARK: Content

    func update(_ newModel: TileModel, context: TileRenderContext, now: Date) {
        let kindChanged = newModel.item.kind != model.item.kind
        model = newModel
        let item = newModel.item
        let key = Self.renderKey(for: newModel, context: context)
        let size = context.base

        host.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        for layer in [backing, icon, ring, missing] { layer.frame = host.bounds }
        glow.frame = host.bounds.insetBy(dx: -size * 0.45, dy: -size * 0.45)
        glow.isHidden = false

        if key != renderKey || kindChanged {
            renderKey = key
            renderBitmap(item: item, context: context, now: now)
        }
        updateBacking(item: item, context: context)
        updateIndicator(context: context)
        updateGlow(context: context)

        let dimmed = context.dimsNonRunning && item.kind == .file && item.bundleIdentifier != nil && !newModel.isRunning
        host.opacity = dimmed ? 0.55 : 1
        updateBadge(item: item, context: context)
        minus.isHidden = !context.isEditing
        updateLabel(item: item, context: context)
        updateRing(context: context)
    }

    private static func renderKey(for model: TileModel, context: TileRenderContext) -> String {
        let item = model.item
        var parts: [String] = [item.kind.rawValue, "\(context.pixels)", "\(Int(context.saturation * 100))",
                               context.darkForeground ? "d" : "l", context.darkScheme ? "D" : "L"]
        switch item.kind {
        case .file:
            parts += [item.path, item.customIconPath ?? "", "\(item.isMissing)",
                      model.isRunning || !context.dimsNonRunning ? "c" : "g",
                      isLiveIcon(item) ? "\(context.liveStamp)" : ""]
        case .action: parts += [item.symbolName]
        case .widget: parts += [item.widget.rawValue, "\(item.widgetOptions)", "\(model.widget.map { "\($0)" } ?? "")"]
        case .group: parts += item.memberPaths.prefix(4).map { $0 }
        case .tray: parts += ["\(item.memberPaths.isEmpty)"]
        case .trash: parts += ["\(model.isFull)"]
        case .separator: break
        }
        return parts.joined(separator: "|")
    }

    static func isLiveIcon(_ item: DockItem) -> Bool {
        item.kind == .file && ["com.apple.iCal", "com.apple.clock"].contains(item.bundleIdentifier ?? "")
    }

    private func renderBitmap(item: DockItem, context: TileRenderContext, now: Date) {
        let pixels = context.pixels
        let fg = context.foreground
        var image: CGImage?
        switch item.kind {
        case .file:
            let dimmed = context.dimsNonRunning && item.bundleIdentifier != nil && !model.isRunning
            let saturation = dimmed ? 0 : context.saturation
            switch item.bundleIdentifier {
            case "com.apple.iCal" where item.customIconPath == nil:
                image = TileImages.shared.calendarIcon(date: now, pixels: pixels)
            case "com.apple.clock" where item.customIconPath == nil:
                image = TileImages.shared.clockIcon(date: now, pixels: pixels)
            default:
                image = TileImages.shared.fileIcon(path: item.path, customIconPath: item.customIconPath,
                                                   pixels: pixels, saturation: saturation)
            }
        case .action:
            image = TileImages.shared.symbol(item.symbolName, fill: 0.5, color: fg, pixels: pixels)
        case .widget:
            image = MainActor.assumeIsolated {
                WidgetFaceRenderer.image(kind: item.widget, snapshot: model.widget ?? WidgetSnapshot(),
                                         options: item.widgetOptions, side: context.maxSize, scale: context.scale,
                                         dark: context.darkScheme, foreground: Color(nsColor: fg),
                                         accent: Color(nsColor: context.accent.nsColor))
            }
        case .group:
            image = TileImages.shared.groupIcon(memberPaths: item.memberPaths, pixels: pixels, saturation: context.saturation)
                ?? TileImages.shared.symbol("square.stack.3d.up", fill: 0.45, color: fg, pixels: pixels)
        case .tray:
            image = TileImages.shared.symbol(item.memberPaths.isEmpty ? "tray" : "tray.full.fill", fill: 0.5, color: fg, pixels: pixels)
        case .trash:
            let name = model.isFull ? NSImage.trashFullName : NSImage.trashEmptyName
            if let source = NSImage(named: name) {
                image = TileImages.shared.rasterized(source, pixels: pixels, key: "trash|\(model.isFull)|\(pixels)")
            }
        case .separator:
            image = nil
        }
        icon.contents = image
        icon.contentsScale = context.scale

        // A missing target stays visible but obviously broken, rather than
        // vanishing and leaving the user wondering where their tile went.
        let isMissing = item.kind == .file && item.isMissing
        icon.opacity = isMissing ? 0.35 : 1
        missing.isHidden = !isMissing
        if isMissing {
            missing.contents = TileImages.shared.symbol("exclamationmark.triangle.fill", fill: 0.3,
                                                        color: NSColor.systemOrange, pixels: 64)
            missing.contentsGravity = .bottomRight
            missing.bounds = host.bounds
        }
    }

    private func updateBacking(item: DockItem, context: TileRenderContext) {
        let wantsBacking = [.action, .widget, .tray, .group].contains(item.kind) && context.tileShape != .none
        backing.isHidden = !wantsBacking
        guard wantsBacking else { return }
        backing.cornerRadius = context.tileShape.cornerRadius(for: context.base)
        backing.cornerCurve = context.tileShape == .rounded ? .circular : .continuous
        backing.backgroundColor = context.foreground.withAlphaComponent(CGFloat(context.backingOpacity)).cgColor
    }

    private func updateIndicator(context: TileRenderContext) {
        let running = model.isRunning
        switch context.indicatorStyle {
        case .dot:
            indicator.path = CGPath(ellipseIn: CGRect(x: -2, y: -2, width: 4, height: 4), transform: nil)
            indicator.fillColor = context.indicatorColor.cgColor
        case .bar:
            let width = max(10, context.base * 0.34)
            indicator.path = CGPath(roundedRect: CGRect(x: -width / 2, y: -1.5, width: width, height: 3),
                                    cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            indicator.fillColor = context.indicatorColor.cgColor
        case .ring, .glow, .none:
            indicator.path = nil
        }
        indicator.opacity = running && context.indicatorStyle.needsGutter ? 0.85 : 0
    }

    private func updateRing(context: TileRenderContext) {
        guard context.indicatorStyle == .ring else { ring.opacity = 0; return }
        let radius = context.tileShape == .none ? context.base * 0.22 : context.tileShape.cornerRadius(for: context.base)
        ring.path = CGPath(roundedRect: host.bounds.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil)
        ring.strokeColor = context.indicatorColor.cgColor
        ring.lineWidth = 2
        ring.opacity = model.isRunning ? 0.9 : 0
    }

    private func updateGlow(context: TileRenderContext) {
        let key = "\(context.indicatorColor.hashValue)"
        if key != glowKey {
            glowKey = key
            glow.contents = GlowImage.image(color: context.indicatorColor)
        }
    }

    private func updateBadge(item: DockItem, context: TileRenderContext) {
        let count = item.kind == .tray ? item.memberPaths.count : 0
        badge.isHidden = count == 0
        guard count > 0 else { return }
        badge.contents = TileImages.shared.countBadge(count, pixels: Int(22 * context.scale))
        badge.contentsScale = context.scale
        badge.bounds = CGRect(x: 0, y: 0, width: 22, height: 14)
    }

    private func updateLabel(item: DockItem, context: TileRenderContext) {
        label.isHidden = !context.showsLabels || item.kind == .separator
        guard context.showsLabels else { return }
        label.string = item.displayName
        label.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        label.fontSize = 9
        label.foregroundColor = context.foreground.withAlphaComponent(0.8).cgColor
        label.contentsScale = context.scale
        label.bounds = CGRect(x: 0, y: 0, width: context.base + 14, height: 12)
    }

    // MARK: Per-frame state

    /// Highlights a tile while something is dragged over it.
    func setDropHighlight(_ on: Bool, context: TileRenderContext) {
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 2.5
        let radius = context.tileShape == .none ? context.base * 0.22 : context.tileShape.cornerRadius(for: context.base)
        ring.path = CGPath(roundedRect: host.bounds.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil)
        ring.opacity = on ? 1 : (context.indicatorStyle == .ring && model.isRunning ? 0.9 : 0)
        if !on { updateRing(context: context) }
    }

    func setHoverGlow(_ amount: CGFloat, context: TileRenderContext) {
        let running = context.indicatorStyle == .glow && model.isRunning ? 0.55 : 0
        glow.opacity = Float(max(amount, CGFloat(running)))
    }
}

/// A soft round bloom, cached per colour: the hover glow is one of these under
/// the tile with its opacity changed, instead of a blurred shadow recomputed
/// every frame.
enum GlowImage {
    private static var cache: [CodableColor: CGImage] = [:]

    static func image(color: CodableColor) -> CGImage? {
        if let cached = cache[color] { return cached }
        let side = 128
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [color.with(alpha: 0.9).cgColor, color.with(alpha: 0.28).cgColor,
                                                 color.with(alpha: 0).cgColor] as CFArray,
                                        locations: [0, 0.5, 1]) else { return nil }
        let center = CGPoint(x: side / 2, y: side / 2)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                               endRadius: CGFloat(side) / 2, options: [])
        let image = ctx.makeImage()
        if let image { cache[color] = image }
        return image
    }
}
