import AppKit
import QuartzCore
import SwiftUI
import Combine

/// The shape every plate, mask and clip in the dock agrees on.
enum PlateShape {
    static func path(in rect: CGRect, radius: CGFloat, continuous: Bool) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let r = min(max(radius, 0), limit)
        guard r > 0.01 else { return CGPath(rect: rect, transform: nil) }
        let style: RoundedCornerStyle = continuous ? .continuous : .circular
        return RoundedRectangle(cornerRadius: r, style: style).path(in: rect).cgPath
    }

    /// An alpha mask the exact size of a view, for `NSVisualEffectView.maskImage`.
    /// Without one the blur fills the whole rectangle behind the rounded plate,
    /// which is the faint box that used to show around every extra dock.
    static func maskImage(size: CGSize, radius: CGFloat, continuous: Bool) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path(in: rect, radius: radius, continuous: continuous))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            return true
        }
    }
}

/// Draws a `GlassTheme` as a rounded plate, with its shadow and glow.
///
/// Everything that doesn't move is rendered once into bitmaps and gradient
/// layers that the render server simply composites. The old SwiftUI surface
/// re-evaluated every layer — gradients, a blurred stroke, a tiled blend-mode
/// grain image, two blurred shadows — on every pointer movement; here the only
/// thing that moves when you hover is one pre-rendered highlight image.
///
/// Subview order is the draw order: shadow and glow at the bottom, then the
/// system blur (or Liquid Glass), then the decoration on top.
final class GlassSurfaceView: NSView {
    enum Backdrop {
        /// Blur what is behind the window — a floating dock panel.
        case behindWindow
        /// Blur what is behind the view *inside* its window — previews.
        case withinWindow
        /// No system blur at all; a flat translucent stand-in. For swatches,
        /// where a dozen live blurs would cost far more than they show.
        case simulated
    }

    private(set) var theme: GlassTheme
    var backdrop: Backdrop { didSet { if backdrop != oldValue { effectKey = nil; refresh() } } }
    /// Shrinks radii and strokes for small previews and swatches.
    var detailScale: CGFloat { didSet { if detailScale != oldValue { refresh() } } }

    /// The visible plate within this view's bounds.
    var plateFrame: CGRect { didSet { if plateFrame != oldValue { needsLayout = true } } }

    private let shadowHost = NSView()
    private let shadowLayer = CALayer()
    private let glowLayer = CALayer()
    private let shadowMask = CAShapeLayer()
    private let glowMask = CAShapeLayer()

    private var effectView: NSView?
    private let simulatedBase = CALayer()
    private let decorHost = NSView()
    private let tintLayer = CAGradientLayer()
    private let lowerLayer = CALayer()
    private let highlightLayer = CALayer()
    private let upperLayer = CALayer()

    private var effectKey: EffectKey?
    private var bakeKey: BakeKey?
    private var highlightKey: HighlightKey?
    private var lightPoint: CGPoint?
    private var cancellable: AnyCancellable?

    private struct EffectKey: Equatable {
        var kind: Int
        var substrate: GlassSubstrate
        var appearance: GlassAppearance
        var variant: NativeGlassVariant
        var backdrop: Int
    }

    private struct BakeKey: Equatable {
        var size: CGSize
        var scale: CGFloat
        var radius: CGFloat
        var continuous: Bool
        var depth: Double
        var lensing: Double
        var grain: Double
        var rimIntensity: Double
        var rimWidth: Double
        var rimColor: CodableColor
        var detail: CGFloat
        var drawsOptics: Bool
    }

    private struct HighlightKey: Equatable {
        var intensity: Double
        var spread: Double
    }

    init(theme: GlassTheme, backdrop: Backdrop = .behindWindow, detailScale: CGFloat = 1) {
        self.theme = theme
        self.backdrop = backdrop
        self.detailScale = detailScale
        self.plateFrame = .zero
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        shadowHost.wantsLayer = true
        shadowHost.layer?.masksToBounds = false
        shadowHost.layer?.addSublayer(shadowLayer)
        shadowHost.layer?.addSublayer(glowLayer)
        shadowLayer.mask = shadowMask
        glowLayer.mask = glowMask
        for mask in [shadowMask, glowMask] { mask.fillRule = .evenOdd; mask.fillColor = CGColor(gray: 0, alpha: 1) }
        addSubview(shadowHost)

        decorHost.wantsLayer = true
        decorHost.layer?.masksToBounds = true
        for layer in [tintLayer, lowerLayer, highlightLayer, upperLayer] {
            layer.contentsGravity = .resize
            decorHost.layer?.addSublayer(layer)
        }
        addSubview(decorHost)
        simulatedBase.isHidden = true

        // The macOS 27 transparency slider only matters to themes that follow it.
        cancellable = SystemGlass.shared.$amount.dropFirst().sink { [weak self] _ in
            guard let self, self.theme.followsSystemGlass else { return }
            self.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Public

    func setTheme(_ newTheme: GlassTheme) {
        guard newTheme != theme else { return }
        theme = newTheme
        refresh()
    }

    /// Moves the specular bloom. `nil` parks it at the theme's resting light
    /// source. Points are in this view's coordinates.
    func setLight(at point: CGPoint?) {
        lightPoint = point
        placeHighlight()
    }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        bakeKey = nil
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        bakeKey = nil
        refresh()
    }

    override func layout() {
        super.layout()
        shadowHost.frame = bounds
        effectView?.frame = plateFrame
        decorHost.frame = plateFrame
        refresh()
    }

    // MARK: Refresh

    private var scaleFactor: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private var radius: CGFloat { theme.resolvedCornerRadius(for: plateFrame.size) * detailScale }

    /// Where on the glass the opaque/clear slider currently sits, as an offset
    /// applied on top of the theme's own values.
    private var systemBias: Double { theme.followsSystemGlass && theme.fillStyle != .native ? SystemGlass.shared.bias : 0 }

    private var effectiveFill: ThemeFillStyle {
        guard theme.fillStyle == .native else { return theme.fillStyle }
        // Native glass needs macOS 26, and a swatch can't afford a live glass
        // view each — both fall back to the custom glass look.
        if #unavailable(macOS 26.0) { return .glass }
        return backdrop == .simulated ? .glass : .native
    }

    func refresh() {
        guard plateFrame.width > 1, plateFrame.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let fill = effectiveFill
        let r = radius
        let plateBounds = CGRect(origin: .zero, size: plateFrame.size)
        let platePath = PlateShape.path(in: plateBounds, radius: r, continuous: theme.continuousCorners)

        // Effect view (blur / Liquid Glass)
        updateEffectView(fill: fill, radius: r)

        // Decoration host: rounded clip, plate-sized layers.
        if let layer = decorHost.layer {
            layer.cornerRadius = r
            layer.cornerCurve = theme.continuousCorners ? .continuous : .circular
        }
        let showsDecoration = fill != .native
        decorHost.isHidden = !showsDecoration
        for layer in [tintLayer, lowerLayer, upperLayer] { layer.frame = plateBounds }

        let bias = systemBias
        let translucency = min(max(theme.translucency + bias * 0.12, 0.05), 1)
        effectView?.alphaValue = CGFloat(translucency)
        decorHost.alphaValue = CGFloat(fill == .glass ? translucency : min(max(translucency, 0.05), 1))

        applyTint(fill: fill, bias: bias)
        applyHighlight(plateBounds: plateBounds)
        bake(plateBounds: plateBounds, radius: r, drawsOptics: showsDecoration)
        applyShadows(platePath: platePath)
        placeHighlight()
    }

    // MARK: Effect view

    private func updateEffectView(fill: ThemeFillStyle, radius r: CGFloat) {
        let kind: Int
        switch fill {
        case .native: kind = 2
        case .gradient: kind = theme.tintIntensity < 0.97 ? 1 : 0
        case .glass: kind = 1
        }
        let backdropIndex: Int
        switch backdrop { case .behindWindow: backdropIndex = 0; case .withinWindow: backdropIndex = 1; case .simulated: backdropIndex = 2 }
        let key = EffectKey(kind: backdrop == .simulated && kind != 2 ? 0 : kind,
                            substrate: theme.substrate, appearance: theme.appearance,
                            variant: theme.nativeVariant, backdrop: backdropIndex)
        if key != effectKey {
            effectKey = key
            effectView?.removeFromSuperview()
            effectView = nil
            maskKey = nil
            simulatedBase.removeFromSuperlayer()

            switch key.kind {
            case 2:
                if #available(macOS 26.0, *) {
                    let glass = NSGlassEffectView()
                    glass.contentView = NSView()
                    effectView = glass
                }
            case 1:
                let blur = NSVisualEffectView()
                blur.blendingMode = backdrop == .withinWindow ? .withinWindow : .behindWindow
                blur.state = .active
                blur.material = theme.substrate.material
                blur.appearance = theme.appearance.nsAppearance
                effectView = blur
            default:
                break
            }
            if let view = effectView {
                addSubview(view, positioned: .above, relativeTo: shadowHost)
            }
            if backdrop == .simulated, key.kind != 2 {
                // A flat frosted stand-in, tuned per appearance.
                decorHost.layer?.insertSublayer(simulatedBase, at: 0)
                simulatedBase.isHidden = false
            }
        }

        effectView?.frame = plateFrame

        if let blur = effectView as? NSVisualEffectView {
            blur.material = theme.substrate.material
            blur.appearance = theme.appearance.nsAppearance
            let size = plateFrame.size
            let mask = MaskKey(size: size, radius: r, continuous: theme.continuousCorners)
            if mask != maskKey {
                blur.maskImage = PlateShape.maskImage(size: size, radius: r, continuous: theme.continuousCorners)
                maskKey = mask
            }
        } else if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
            glass.cornerRadius = r
            glass.style = theme.nativeVariant == .clear ? .clear : .regular
            let tint = theme.tint.nsColor.withAlphaComponent(CGFloat(theme.tintIntensity) * (theme.tintIntensity > 0.01 ? 0.7 : 0))
            glass.tintColor = theme.tintIntensity > 0.01 ? tint : nil
            if #available(macOS 27.0, *) { glass.effectIsInteractive = theme.nativeInteractive }
        }

        if simulatedBase.superlayer != nil {
            simulatedBase.frame = CGRect(origin: .zero, size: plateFrame.size)
            let dark = theme.appearance == .dark || (theme.appearance == .system && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            simulatedBase.backgroundColor = dark ? CGColor(gray: 0.08, alpha: 0.45) : CGColor(gray: 1, alpha: 0.38)
        }
    }

    private struct MaskKey: Equatable { var size: CGSize; var radius: CGFloat; var continuous: Bool }
    private var maskKey: MaskKey?

    // MARK: Tint

    private func gradientPoints(angle: Double) -> (CGPoint, CGPoint) {
        let radians = angle * .pi / 180
        // 0° runs straight down, 45° towards the bottom-right, like Goorgle's
        // palettes. CALayer's unit square is y-up, hence the sign on `cos`.
        let start = CGPoint(x: 0.5 - sin(radians) / 2, y: 0.5 + cos(radians) / 2)
        let end = CGPoint(x: 0.5 + sin(radians) / 2, y: 0.5 - cos(radians) / 2)
        return (start, end)
    }

    private func applyTint(fill: ThemeFillStyle, bias: Double) {
        tintLayer.removeAnimation(forKey: "hueDrift")
        guard fill != .native else { tintLayer.isHidden = true; return }
        tintLayer.isHidden = false
        var colors = theme.tintStops.map(\.cgColor)
        if colors.count == 1 { colors.append(colors[0]) }
        tintLayer.colors = colors
        (tintLayer.startPoint, tintLayer.endPoint) = gradientPoints(angle: theme.tintAngle)
        // A gradient fill is the palette itself, so it stays vivid; glass only
        // washes the palette lightly over the blur, and follows the system slider.
        let intensity = fill == .gradient
            ? theme.tintIntensity
            : min(max(theme.tintIntensity * (1 + bias * 0.6), 0), 1)
        tintLayer.opacity = Float(intensity)

        // Hue drift is a keyframe animation the render server runs by itself,
        // so a drifting theme costs the app no timer and no wakeups.
        guard theme.tintCycleSeconds > 1 else { return }
        let stops = theme.tintStops
        let steps = 8
        let frames: [[CGColor]] = (0...steps).map { k in
            var row = stops.map { $0.hueRotated(by: Double(k) / Double(steps)).cgColor }
            if row.count == 1 { row.append(row[0]) }
            return row
        }
        let animation = CAKeyframeAnimation(keyPath: "colors")
        animation.values = frames
        animation.duration = theme.tintCycleSeconds
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        tintLayer.add(animation, forKey: "hueDrift")
    }

    // MARK: Highlight

    private func applyHighlight(plateBounds: CGRect) {
        let key = HighlightKey(intensity: theme.specularIntensity, spread: theme.specularSpread)
        if key != highlightKey {
            highlightKey = key
            highlightLayer.contents = Self.radialHighlight(intensity: theme.specularIntensity)
        }
        let diameter = max(min(plateBounds.width, plateBounds.height) * CGFloat(theme.specularSpread) * 2, 8)
        highlightLayer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        highlightLayer.isHidden = theme.specularIntensity < 0.01 || effectiveFill == .native
    }

    private var restingLight: CGPoint {
        CGPoint(x: plateFrame.width * 0.25, y: plateFrame.height * 0.9)
    }

    private func placeHighlight() {
        guard plateFrame.width > 1 else { return }
        let target: CGPoint
        if let lightPoint {
            // Clamped to the plate, so a pointer in the magnification overhang
            // still lights the glass instead of sliding off it.
            target = CGPoint(x: min(max(lightPoint.x - plateFrame.minX, 0), plateFrame.width),
                             y: min(max(lightPoint.y - plateFrame.minY, 0), plateFrame.height))
        } else {
            target = restingLight
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.position = target
        CATransaction.commit()
    }

    private static func radialHighlight(intensity: Double) -> CGImage? {
        let side = 256
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(gray: 1, alpha: CGFloat(intensity * 0.5)),
                      CGColor(gray: 1, alpha: CGFloat(intensity * 0.14)),
                      CGColor(gray: 1, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                        locations: [0, 0.45, 1]) else { return nil }
        let center = CGPoint(x: side / 2, y: side / 2)
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                               endRadius: CGFloat(side) / 2, options: [])
        return ctx.makeImage()
    }

    // MARK: Baked decoration

    private func bake(plateBounds: CGRect, radius r: CGFloat, drawsOptics: Bool) {
        let scale = scaleFactor
        let key = BakeKey(size: plateBounds.size, scale: scale, radius: r, continuous: theme.continuousCorners,
                          depth: theme.depth, lensing: theme.lensing, grain: theme.grain,
                          rimIntensity: theme.rimIntensity, rimWidth: theme.rimWidth, rimColor: theme.rimColor,
                          detail: detailScale, drawsOptics: drawsOptics)
        guard key != bakeKey else { return }
        bakeKey = key
        guard drawsOptics else {
            lowerLayer.contents = nil
            upperLayer.contents = nil
            return
        }
        let lower = Self.render(size: plateBounds.size, scale: scale) { ctx in
            self.drawLower(ctx, bounds: plateBounds, radius: r)
        }
        let upper = Self.render(size: plateBounds.size, scale: scale) { ctx in
            self.drawUpper(ctx, bounds: plateBounds, radius: r)
        }
        lowerLayer.contents = lower
        upperLayer.contents = upper
        lowerLayer.contentsScale = scale
        upperLayer.contentsScale = scale
    }

    private static func render(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
        let width = max(Int((size.width * scale).rounded(.up)), 1)
        let height = max(Int((size.height * scale).rounded(.up)), 1)
        guard width <= 8192, height <= 8192,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage()
    }

    private func lightGradientPoints(in bounds: CGRect) -> (CGPoint, CGPoint) {
        let light = CGPoint(x: bounds.width * 0.25, y: bounds.height * 0.9)
        return (light, CGPoint(x: bounds.width - light.x, y: bounds.height - light.y))
    }

    /// Depth falloff and edge lensing — the parts that give the pane thickness.
    private func drawLower(_ ctx: CGContext, bounds: CGRect, radius r: CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let path = PlateShape.path(in: bounds, radius: r, continuous: theme.continuousCorners)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()

        // Light lifts the top face and sinks the bottom one. Plain alpha rather
        // than the old overlay blend, with values scaled to match its strength.
        if theme.depth > 0.001 {
            let colors = [CGColor(gray: 1, alpha: CGFloat(theme.depth * 0.20)),
                          CGColor(gray: 1, alpha: 0),
                          CGColor(gray: 0, alpha: CGFloat(theme.depth * 0.20))] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.45, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.maxY),
                                       end: CGPoint(x: bounds.midX, y: bounds.minY), options: [])
            }
        }

        // Lensing: a soft bright band hugging the border, brightest facing the
        // light, built from a few strokes of falling width so it fades inward.
        if theme.lensing > 0.01 {
            let (from, to) = lightGradientPoints(in: bounds)
            let rim = theme.rimColor
            let passes = 5
            for pass in 1...passes {
                let width = CGFloat(pass) * 2.4 * CGFloat(theme.lensing) * detailScale + 1
                let strength = CGFloat(theme.lensing) / CGFloat(passes) * 0.55
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setLineWidth(width)
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                let colors = [rim.with(alpha: Double(strength)).cgColor,
                              rim.with(alpha: Double(strength) * 0.1).cgColor,
                              rim.with(alpha: Double(strength) * 0.4).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1]) {
                    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                }
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }

    /// Grain and the crisp rim light — the top-most details.
    private func drawUpper(_ ctx: CGContext, bounds: CGRect, radius r: CGFloat) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let path = PlateShape.path(in: bounds, radius: r, continuous: theme.continuousCorners)

        if theme.grain > 0.005, let noise = NoiseTile.shared.image {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setAlpha(CGFloat(theme.grain) * 0.55)
            let tile = CGFloat(noise.width) / 2
            var y: CGFloat = 0
            while y < bounds.height {
                var x: CGFloat = 0
                while x < bounds.width {
                    ctx.draw(noise, in: CGRect(x: x, y: y, width: tile, height: tile))
                    x += tile
                }
                y += tile
            }
            ctx.restoreGState()
        }

        let rimWidth = max(0.5, CGFloat(theme.rimWidth) * detailScale)
        if theme.rimIntensity > 0.01, theme.rimWidth > 0.01 {
            let inset = rimWidth / 2
            let rect = bounds.insetBy(dx: inset, dy: inset)
            let rimPath = PlateShape.path(in: rect, radius: max(r - inset, 0), continuous: theme.continuousCorners)
            let (from, to) = lightGradientPoints(in: bounds)
            let rim = theme.rimColor
            let i = theme.rimIntensity
            ctx.saveGState()
            ctx.addPath(rimPath)
            ctx.setLineWidth(rimWidth)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let colors = [rim.with(alpha: i * 0.85).cgColor,
                          rim.with(alpha: i * 0.12).cgColor,
                          rim.with(alpha: i * 0.40).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1]) {
                ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
        }
    }

    // MARK: Shadow and glow

    private func applyShadows(platePath: CGPath) {
        let frame = plateFrame
        var move = CGAffineTransform(translationX: frame.minX, y: frame.minY)
        guard let path = platePath.copy(using: &move) else { return }
        let scale = detailScale

        shadowLayer.frame = bounds
        shadowLayer.shadowPath = path
        shadowLayer.shadowColor = theme.shadowColor.cgColor
        shadowLayer.shadowOpacity = Float(theme.shadowOpacity)
        shadowLayer.shadowRadius = CGFloat(theme.shadowRadius) * 0.6 * scale
        shadowLayer.shadowOffset = CGSize(width: 0, height: -CGFloat(theme.shadowYOffset) * scale)

        glowLayer.frame = bounds
        glowLayer.shadowPath = path
        glowLayer.shadowColor = theme.glowColor.cgColor
        glowLayer.shadowOpacity = Float(min(theme.glowIntensity * 0.9, 1))
        glowLayer.shadowRadius = max(1, 18 * CGFloat(theme.glowIntensity)) * 0.6 * scale
        glowLayer.shadowOffset = .zero
        glowLayer.isHidden = theme.glowIntensity < 0.01

        // Both are clipped to the *outside* of the plate: a translucent pane
        // must not show its own shadow through itself.
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -4, dy: -4))
        outside.addPath(path)
        for mask in [shadowMask, glowMask] {
            mask.frame = bounds
            mask.path = outside
        }
    }
}

/// A single small tile of two-tone noise, generated once and reused by every
/// surface. Light and dark specks, each with a random alpha, so it averages out
/// to neutral under plain alpha blending — a mid-grey noise would wash the
/// plate grey.
final class NoiseTile {
    static let shared = NoiseTile()
    let image: CGImage?

    private init() {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x2545F4914F6CDD1D
        for index in stride(from: 0, to: pixels.count, by: 4) {
            // xorshift64*: deterministic, so the grain can't shimmer between launches.
            seed ^= seed >> 12; seed ^= seed << 25; seed ^= seed >> 27
            let n = Double((seed &* 0x2545F4914F6CDD1D) >> 56) / 255
            let light = n > 0.5
            let alpha = abs(n - 0.5) * 2
            let value: Double = light ? 1 : 0
            // Premultiplied.
            pixels[index] = UInt8(value * alpha * 255)
            pixels[index + 1] = UInt8(value * alpha * 255)
            pixels[index + 2] = UInt8(value * alpha * 255)
            pixels[index + 3] = UInt8(alpha * 255)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        image = provider.flatMap {
            CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }
}

/// SwiftUI host for a surface, used by the theme preview and the swatches.
struct GlassSurfacePreview: NSViewRepresentable {
    let theme: GlassTheme
    var backdrop: GlassSurfaceView.Backdrop = .withinWindow
    var detailScale: CGFloat = 1
    /// Space around the plate for its shadow and glow.
    var margin: CGFloat = 0
    var light: CGPoint?

    func makeNSView(context: Context) -> GlassSurfaceView {
        GlassSurfaceView(theme: theme, backdrop: backdrop, detailScale: detailScale)
    }

    func updateNSView(_ view: GlassSurfaceView, context: Context) {
        view.backdrop = backdrop
        view.detailScale = detailScale
        view.plateFrame = view.bounds.insetBy(dx: margin, dy: margin)
        view.setTheme(theme)
        view.setLight(at: light)
    }
}
