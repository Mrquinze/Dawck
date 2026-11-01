import AppKit
import CoreImage

/// Renders and caches the bitmaps the tile layers display.
///
/// Tiles are bitmap layers, so hovering only ever moves and scales textures
/// that already exist. Each bitmap is rendered once, at the largest size the
/// tile can reach (including magnified), so scaling it *down* at rest stays
/// crisp and scaling it up never blurs — the old path asked the filesystem for
/// an icon, and re-rasterised it, during every body evaluation of every frame.
final class TileImages {
    static let shared = TileImages()

    private final class Box {
        let image: CGImage
        let made = Date()
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let maxAge: TimeInterval = 600

    private init() {
        // ~48 MB of bitmaps is plenty for the handful of tiles a dock holds.
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func removeAll() { cache.removeAllObjects() }

    private func cached(_ key: String, make: () -> CGImage?) -> CGImage? {
        if let box = cache.object(forKey: key as NSString), Date().timeIntervalSince(box.made) < maxAge {
            return box.image
        }
        guard let image = make() else { return nil }
        cache.setObject(Box(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return image
    }

    // MARK: Drawing helpers

    private func context(pixels: Int) -> CGContext? {
        CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Rasterises any `NSImage` (the Trash icons, for instance) once, at `pixels`.
    func rasterized(_ image: NSImage, pixels: Int, key: String) -> CGImage? {
        cached("r|\(key)") { rasterize(image, pixels: pixels) }
    }

    /// A short run of text (a collapsed dock's button label) as a bitmap.
    func text(_ string: String, color: NSColor, height: CGFloat, scale: CGFloat) -> CGImage? {
        let font = NSFont.systemFont(ofSize: height * 0.58, weight: .semibold)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        let width = Int(ceil((size.width + 2) * scale)), tall = Int(ceil(height * scale))
        guard width > 0, tall > 0, let ctx = CGContext(data: nil, width: width, height: tall, bitsPerComponent: 8, bytesPerRow: 0,
                                                       space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        attributed.draw(at: NSPoint(x: 1, y: (height - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// The small red count badge shown on trays.
    func countBadge(_ count: Int, pixels: Int) -> CGImage? {
        cached("b|\(count)|\(pixels)") {
            let width = pixels, height = Int(Double(pixels) * 14 / 22)
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1))
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                               cornerWidth: CGFloat(height) / 2, cornerHeight: CGFloat(height) / 2, transform: nil))
            ctx.fillPath()
            let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let text = NSAttributedString(string: count > 99 ? "99+" : "\(count)", attributes: [
                .font: NSFont.systemFont(ofSize: CGFloat(height) * 0.68, weight: .bold), .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }
    }

    /// The red minus shown on a tile while the dock is being edited.
    func minusBadge(pixels: Int) -> CGImage? {
        cached("m|\(pixels)") {
            guard let ctx = context(pixels: pixels) else { return nil }
            let side = CGFloat(pixels)
            ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.03), blur: side * 0.08, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: side * 0.08, y: side * 0.08, width: side * 0.84, height: side * 0.84))
            ctx.setShadow(offset: .zero, blur: 0)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(side * 0.1)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: side * 0.28, y: side * 0.5))
            ctx.addLine(to: CGPoint(x: side * 0.72, y: side * 0.5))
            ctx.strokePath()
            return ctx.makeImage()
        }
    }

    private func rasterize(_ image: NSImage, pixels: Int) -> CGImage? {
        guard let ctx = context(pixels: pixels) else { return nil }
        ctx.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func adjusted(_ image: CGImage, saturation: Double) -> CGImage {
        guard abs(saturation - 1) > 0.01 else { return image }
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let result = ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: colorSpace)
        else { return image }
        return result
    }

    // MARK: File icons

    /// An app, folder or file icon at `pixels`×`pixels`, with the theme's
    /// saturation baked in.
    func fileIcon(path: String, customIconPath: String?, pixels: Int, saturation: Double) -> CGImage? {
        let key = "f|\(path)|\(customIconPath ?? "")|\(pixels)|\(Int(saturation * 100))"
        return cached(key) {
            let source: NSImage
            if let customIconPath, !customIconPath.isEmpty, let custom = Self.loadCustomIcon(customIconPath) {
                source = custom
            } else {
                source = NSWorkspace.shared.icon(forFile: path)
            }
            guard let raw = rasterize(source, pixels: pixels) else { return nil }
            return adjusted(raw, saturation: saturation)
        }
    }

    /// Custom icons are read from paths the user (or an imported profile) named,
    /// so they are checked before being handed to the image decoders: a regular
    /// file, of a sane size, with an image extension.
    static func loadCustomIcon(_ path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard ["png", "jpg", "jpeg", "tiff", "tif", "icns", "heic", "gif"].contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 20 * 1024 * 1024
        else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: Symbols

    /// A template SF Symbol drawn in `color`, centred in a square bitmap.
    func symbol(_ name: String, fill fraction: CGFloat, color: NSColor, pixels: Int, weight: NSFont.Weight = .medium) -> CGImage? {
        let key = "s|\(name)|\(Int(fraction * 100))|\(color.hashValue)|\(pixels)|\(weight.rawValue)"
        return cached(key) {
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil)
            else { return nil }
            let configured = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: CGFloat(pixels) * fraction, weight: weight)
            ) ?? base
            let tinted = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { rect in
                let aspect = configured.size.width / max(configured.size.height, 1)
                let height = min(CGFloat(pixels) * fraction, CGFloat(pixels))
                let width = min(height * aspect, CGFloat(pixels))
                let drawn = NSRect(x: (rect.width - width) / 2, y: (rect.height - height) / 2, width: width, height: height)
                configured.draw(in: drawn)
                color.set()
                drawn.fill(using: .sourceIn)
                return true
            }
            return rasterize(tinted, pixels: pixels)
        }
    }

    // MARK: Groups

    /// Up to four member icons laid out 2×2, so a group is recognisable at a
    /// glance instead of being one more generic glyph.
    func groupIcon(memberPaths: [String], pixels: Int, saturation: Double) -> CGImage? {
        let key = "g|\(memberPaths.prefix(4).joined(separator: ","))|\(pixels)|\(Int(saturation * 100))"
        return cached(key) {
            guard let ctx = context(pixels: pixels) else { return nil }
            ctx.interpolationQuality = .high
            let pad = CGFloat(pixels) * 0.14
            let gap = CGFloat(pixels) * 0.04
            let cell = (CGFloat(pixels) - 2 * pad - gap) / 2
            for (index, path) in memberPaths.prefix(4).enumerated() {
                let col = CGFloat(index % 2), row = CGFloat(index / 2)
                let rect = CGRect(x: pad + col * (cell + gap), y: CGFloat(pixels) - pad - cell - row * (cell + gap), width: cell, height: cell)
                if let icon = fileIcon(path: path, customIconPath: nil, pixels: Int(cell.rounded(.up)) * 2, saturation: saturation) {
                    ctx.draw(icon, in: rect)
                }
            }
            return ctx.makeImage()
        }
    }

    // MARK: Live icons

    /// The Calendar icon with today's date on it, like the real Dock's.
    func calendarIcon(date: Date, pixels: Int) -> CGImage? {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: date)
        let weekday = calendar.shortWeekdaySymbols[calendar.component(.weekday, from: date) - 1].uppercased()
        return cached("cal|\(day)|\(weekday)|\(pixels)") {
            guard let ctx = context(pixels: pixels) else { return nil }
            let side = CGFloat(pixels)
            let body = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.06, dy: side * 0.06)
            let radius = body.width * 0.225
            let shape = PlateShape.path(in: body, radius: radius, continuous: true)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.04, color: CGColor(gray: 0, alpha: 0.28))
            ctx.addPath(shape)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()

            let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let red = NSColor(srgbRed: 0.98, green: 0.22, blue: 0.20, alpha: 1)
            let weekdayAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: body.height * 0.15, weight: .semibold), .foregroundColor: red,
                .kern: body.height * 0.012]
            let weekdayString = NSAttributedString(string: weekday, attributes: weekdayAttrs)
            let weekdaySize = weekdayString.size()
            weekdayString.draw(at: NSPoint(x: body.midX - weekdaySize.width / 2, y: body.maxY - body.height * 0.31))
            let dayAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: body.height * 0.54, weight: .light), .foregroundColor: NSColor(white: 0.1, alpha: 1)]
            let dayString = NSAttributedString(string: "\(day)", attributes: dayAttrs)
            let daySize = dayString.size()
            dayString.draw(at: NSPoint(x: body.midX - daySize.width / 2, y: body.minY + body.height * 0.06))
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }
    }

    /// An analogue Clock icon showing the time to the minute.
    func clockIcon(date: Date, pixels: Int) -> CGImage? {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = comps.hour ?? 0, minute = comps.minute ?? 0
        return cached("clk|\(hour % 12)|\(minute)|\(pixels)") {
            guard let ctx = context(pixels: pixels) else { return nil }
            let side = CGFloat(pixels)
            let body = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.06, dy: side * 0.06)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.04, color: CGColor(gray: 0, alpha: 0.3))
            ctx.addPath(PlateShape.path(in: body, radius: body.width * 0.225, continuous: true))
            ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()

            let center = CGPoint(x: body.midX, y: body.midY)
            let dial = body.width * 0.40
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: center.x - dial, y: center.y - dial, width: dial * 2, height: dial * 2))
            ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
            for tick in 0..<12 {
                let angle = CGFloat(tick) / 12 * 2 * .pi
                let long = tick % 3 == 0
                let outer = dial * 0.93, inner = dial * (long ? 0.74 : 0.84)
                ctx.setLineWidth(side * (long ? 0.018 : 0.010))
                ctx.move(to: CGPoint(x: center.x + sin(angle) * inner, y: center.y + cos(angle) * inner))
                ctx.addLine(to: CGPoint(x: center.x + sin(angle) * outer, y: center.y + cos(angle) * outer))
                ctx.strokePath()
            }
            func hand(_ angle: CGFloat, length: CGFloat, width: CGFloat, color: CGColor) {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(width)
                ctx.setLineCap(.round)
                ctx.move(to: center)
                ctx.addLine(to: CGPoint(x: center.x + sin(angle) * length, y: center.y + cos(angle) * length))
                ctx.strokePath()
            }
            let minuteAngle = CGFloat(minute) / 60 * 2 * .pi
            let hourAngle = (CGFloat(hour % 12) + CGFloat(minute) / 60) / 12 * 2 * .pi
            hand(hourAngle, length: dial * 0.50, width: side * 0.032, color: CGColor(gray: 0.1, alpha: 1))
            hand(minuteAngle, length: dial * 0.76, width: side * 0.024, color: CGColor(gray: 0.1, alpha: 1))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: center.x - side * 0.02, y: center.y - side * 0.02, width: side * 0.04, height: side * 0.04))
            return ctx.makeImage()
        }
    }
}
