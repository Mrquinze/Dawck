import AppKit
import QuartzCore
import SwiftUI

/// A transparent view that only hosts layers; clicks fall through to the dock.
final class LayerHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The inside of a dock panel: a glass plate and a row of tile layers.
///
/// This replaces a SwiftUI view that was rebuilt on every pointer movement. The
/// glass is drawn once; each tile is a layer that already exists; hovering
/// computes new positions in a few microseconds and writes them straight to the
/// layers. A display link runs only while the magnification is easing in or
/// out, so a dock at rest, or hovered without moving, costs nothing at all.
final class DockContentView: NSView {
    weak var delegate: DockContentDelegate?

    private(set) var model: DockRenderModel
    private(set) var metrics: DockMetrics

    let surface: GlassSurfaceView
    private var pillSurface: GlassSurfaceView?
    private let pillGlyph = CALayer()
    private let tilesHost = LayerHostView(frame: .zero)
    private let placeholder = CATextLayer()
    private let dropRing = CAShapeLayer()
    private let insertionMarker = CAShapeLayer()

    var tiles: [UUID: TileLayer] = [:]
    var context: TileRenderContext
    private var liveStamp = 0

    // Pointer & animation state
    private var pointer: CGPoint?
    private var pointerM: CGFloat = 0
    private var strength: CGFloat = 0
    private var strengthTarget: CGFloat = 0
    private var strengthVelocity: CGFloat = 0
    private var link: CADisplayLink?
    private var lastLinkTime: CFTimeInterval = 0
    /// Pointer movement is recorded as it arrives and applied once per screen
    /// refresh. A gaming mouse reports a thousand positions a second; laying out
    /// the row for every one of them would spend the frame budget several times
    /// over and show nothing extra.
    private var pointerDirty = false
    private var lightTarget: CGPoint?
    private(set) var layoutTiles: [DockLayout.Tile] = []
    private var layoutIDs: [UUID] = []
    private var hoverID: UUID?

    // Drag & drop state
    var draggingID: UUID?
    var insertionIndex: Int?
    var highlightedTile: UUID?
    var mouseDownTile: UUID?
    var currentIntent: DropIntent?
    var mouseDownPoint: CGPoint = .zero
    var didStartDrag = false

    private(set) var isCollapsed = false

    init(model: DockRenderModel, metrics: DockMetrics) {
        self.model = model
        self.metrics = metrics
        self.surface = GlassSurfaceView(theme: model.theme, backdrop: .behindWindow)
        self.context = DockContentView.makeContext(model: model, metrics: metrics, scale: 2, stamp: 0)
        super.init(frame: NSRect(origin: .zero, size: metrics.windowSize))
        wantsLayer = true
        layer?.masksToBounds = false
        addSubview(surface)
        addSubview(tilesHost)

        placeholder.alignmentMode = .center
        placeholder.isWrapped = false
        placeholder.isHidden = true
        tilesHost.layer?.addSublayer(placeholder)

        for ring in [dropRing, insertionMarker] { ring.fillColor = nil; ring.opacity = 0 }
        dropRing.strokeColor = NSColor.controlAccentColor.cgColor
        dropRing.lineWidth = 2.5
        insertionMarker.strokeColor = NSColor.controlAccentColor.cgColor
        insertionMarker.lineWidth = 3
        insertionMarker.lineCap = .round
        tilesHost.layer?.addSublayer(dropRing)
        tilesHost.layer?.addSublayer(insertionMarker)

        registerForDraggedTypes([.fileURL, DockPasteboard.tileType])
        apply(model: model, metrics: metrics)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { link?.invalidate() }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    // MARK: Metrics and context

    /// Sizes for the window and everything in it.
    static func makeMetrics(model: DockRenderModel, screenLength: CGFloat?) -> DockMetrics {
        let dock = model.dock
        let theme = model.theme
        let base = CGFloat(dock.tileSize)
        let widths = tileWidths(for: model)
        let gap = dock.gap
        let row = widths.isEmpty ? 0 : widths.reduce(0, +) + CGFloat(widths.count - 1) * gap
        let magnifies = dock.hoverStyle == .magnify && dock.magnificationEnabled
        let maxTile = magnifies ? max(CGFloat(dock.magnifiedTileSize), base) : base
        var lift: CGFloat = 6
        switch dock.hoverStyle {
        case .lift: lift += base * 0.26
        case .tilt: lift += base * 0.12
        case .glow: lift += base * 0.3
        default: break
        }
        if model.isEditing { lift += 8 }
        let indicatorGutter: CGFloat = dock.showsRunningIndicators && dock.indicatorStyle.needsGutter ? 6 : 0
        let labelGutter: CGFloat = dock.showsLabels ? 14 : 0
        let shadowReach = CGFloat(theme.shadowRadius) * 1.5 + abs(CGFloat(theme.shadowYOffset))
        let glowReach = CGFloat(theme.glowIntensity) * 34 + 6
        let margin = min(max(ceil(max(shadowReach, glowReach)) + 4, 8), 84)
        let stretch: CGFloat? = dock.layoutMode == .stretch ? screenLength.map { $0 - 2 * CGFloat(dock.edgeMargin) } : nil
        return DockMetrics(edge: dock.edge, count: widths.count, tile: base, maxTile: maxTile, gap: gap,
                           padding: CGFloat(theme.padding), indicatorGutter: indicatorGutter, labelGutter: labelGutter,
                           shadowMargin: margin, liftAllowance: lift,
                           minPlateLength: widths.isEmpty ? 210 : 0, stretchLength: stretch, restRowLength: row)
    }

    static func tileWidths(for model: DockRenderModel) -> [CGFloat] {
        let base = CGFloat(model.dock.tileSize)
        return model.tiles.map { $0.item.kind == .separator ? max(8, base * 0.3) : base }
    }

    private static func makeContext(model: DockRenderModel, metrics: DockMetrics, scale: CGFloat, stamp: Int) -> TileRenderContext {
        let dock = model.dock, theme = model.theme
        let darkForeground = theme.prefersDarkForeground(systemIsDark: model.systemIsDark)
        let darkScheme: Bool
        switch theme.appearance {
        case .dark: darkScheme = true
        case .light: darkScheme = false
        case .system: darkScheme = model.systemIsDark
        }
        // The accent for gauges: a gradient plate gets a foreground-coloured
        // accent (a blue bar on a blue gradient disappears); glass uses the system accent.
        let accent = theme.fillStyle == .gradient
            ? CodableColor(color: Color(nsColor: darkForeground ? .black : .white))
            : CodableColor(color: Color(nsColor: .controlAccentColor))
        return TileRenderContext(
            base: metrics.tile, maxSize: metrics.maxTile, scale: scale,
            saturation: theme.iconSaturation, tileShape: theme.tileShape, backingOpacity: theme.tileBackingOpacity,
            darkForeground: darkForeground, darkScheme: darkScheme,
            indicatorStyle: dock.showsRunningIndicators ? dock.indicatorStyle : .none,
            indicatorColor: dock.indicatorColor, dimsNonRunning: dock.dimsNonRunningApps,
            showsLabels: dock.showsLabels, isEditing: model.isEditing, accent: accent, liveStamp: stamp)
    }

    // MARK: Applying a model

    func apply(model new: DockRenderModel, metrics newMetrics: DockMetrics) {
        model = new
        metrics = newMetrics
        context = Self.makeContext(model: new, metrics: newMetrics, scale: scale, stamp: liveStamp)
        needsLayout = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        surface.setTheme(new.theme)
        pillSurface?.setTheme(pillTheme(new.theme))

        let ids = Set(new.tiles.map(\.id))
        for (id, tile) in tiles where !ids.contains(id) {
            tile.layers.forEach { $0.removeFromSuperlayer() }
            tiles[id] = nil
        }
        let now = Date()
        for model in new.tiles {
            let tile: TileLayer
            if let existing = tiles[model.id] {
                tile = existing
            } else {
                tile = TileLayer(model: model)
                tiles[model.id] = tile
                for layer in tile.layers { tilesHost.layer?.insertSublayer(layer, below: placeholder) }
            }
            tile.update(model, context: context, now: now)
            tile.minus.contents = TileImages.shared.minusBadge(pixels: Int(18 * scale))
            tile.minus.bounds = CGRect(x: 0, y: 0, width: 18, height: 18)
            tile.minus.contentsScale = scale
            tile.host.anchorPoint = metrics.tileAnchor
        }
        updatePlaceholder()
        layoutTilesNow()
    }

    /// Re-renders the live Calendar and Clock icons (a new day, a new minute).
    func refreshLiveIcons() {
        liveStamp += 1
        context.liveStamp = liveStamp
        let now = Date()
        for model in model.tiles where TileLayer.isLiveIcon(model.item) {
            tiles[model.id]?.update(model, context: context, now: now)
        }
    }

    private func updatePlaceholder() {
        let empty = model.tiles.isEmpty
        placeholder.isHidden = !empty || isCollapsed
        guard empty else { return }
        placeholder.string = model.dock.contentMode == .liveDock ? "Mirroring your Dock" : "Drop apps here"
        placeholder.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        placeholder.fontSize = 11
        placeholder.foregroundColor = context.foreground.withAlphaComponent(0.6).cgColor
        placeholder.contentsScale = scale
        placeholder.bounds = CGRect(x: 0, y: 0, width: max(metrics.plateLength - 20, 40), height: 16)
        placeholder.position = CGPoint(x: metrics.plateRect.midX, y: metrics.plateRect.midY)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        surface.frame = bounds
        surface.plateFrame = metrics.plateRect
        tilesHost.frame = bounds
        pillSurface?.frame = bounds
        pillSurface?.plateFrame = pillRect
        positionPillGlyph()
        let ring = PlateShape.path(in: metrics.plateRect.insetBy(dx: -2, dy: -2),
                                   radius: model.theme.resolvedCornerRadius(for: metrics.plateRect.size) + 2,
                                   continuous: model.theme.continuousCorners)
        dropRing.path = ring
        layoutTilesNow()
    }

    private func layoutInput() -> (DockLayout.Input, [UUID]) {
        let active = model.tiles.filter { $0.id != draggingID }
        let widths = active.map { $0.item.kind == .separator ? max(8, metrics.tile * 0.3) : metrics.tile }
        let rowLeading = metrics.padding + max(0, (metrics.plateLength - metrics.restRowLengthExcludingDragged(widths: widths, gap: metrics.gap) - 2 * metrics.padding) / 2)
        var input = DockLayout.Input(
            widths: widths, magnifies: active.map { $0.item.kind != .separator },
            base: metrics.tile, maxSize: metrics.maxTile, gap: metrics.gap, padding: rowLeading,
            pointer: pointer == nil && draggingID == nil ? nil : pointerM, strength: strength)
        input.endSlack = (metrics.maxTile - metrics.tile) * 0.6 + metrics.tile * 0.1
        input.plateLength = metrics.plateLength
        if let insertionIndex {
            input.gapIndex = min(insertionIndex, widths.count)
            input.gapWidth = metrics.tile
        }
        return (input, active.map(\.id))
    }

    /// Computes positions for the current pointer and strength and writes them
    /// to the layers. Called on every pointer movement and display-link tick.
    func layoutTilesNow() {
        let (input, ids) = layoutInput()
        let geometry = DockLayout.compute(input)
        layoutTiles = geometry
        layoutIDs = ids

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let style = model.dock.hoverStyle
        let b = metrics.tile
        let indicatorCross = metrics.padding + metrics.labelGutter + metrics.indicatorGutter / 2
        for (index, id) in ids.enumerated() {
            guard let tile = tiles[id], index < geometry.count else { continue }
            let g = geometry[index]
            if tile.model.item.kind == .separator { for layer in tile.layers { layer.isHidden = true }; continue }
            tile.host.isHidden = false

            var transform = CATransform3DMakeScale(g.scale, g.scale, 1)
            var shift = CGVector.zero
            switch style {
            case .lift:
                let amount = g.proximity * b * 0.22
                shift = CGVector(dx: metrics.inward.dx * amount, dy: metrics.inward.dy * amount)
            case .tilt:
                var tilt = CATransform3DIdentity
                tilt.m34 = -1 / 520
                let angle = g.proximity * 0.32
                tilt = metrics.isHorizontal ? CATransform3DRotate(tilt, metrics.edge == .bottom ? -angle : angle, 1, 0, 0)
                                            : CATransform3DRotate(tilt, metrics.edge == .left ? angle : -angle, 0, 1, 0)
                transform = CATransform3DConcat(transform, tilt)
            default: break
            }
            if shift != .zero { transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(shift.dx, shift.dy, 0)) }

            tile.host.position = metrics.point(m: g.center, c: metrics.iconBase)
            tile.host.transform = transform
            tile.host.zPosition = g.proximity * 20
            tile.setHoverGlow(style == .glow ? g.proximity * 0.9 : 0, context: context)

            tile.indicator.position = metrics.point(m: g.center, c: indicatorCross)
            tile.label.position = metrics.point(m: g.center, c: metrics.padding + metrics.labelGutter / 2)
            let size = b * g.scale
            tile.badge.position = metrics.point(m: g.center + size / 2 - 4, c: metrics.iconBase + size - 4)
            tile.minus.position = metrics.point(m: g.center - size / 2 + 1, c: metrics.iconBase + size - 1)
            for layer in [tile.indicator, tile.label, tile.badge, tile.minus] { layer.zPosition = 30 }
        }
        // The dragged tile has no slot while it is in the air.
        if let draggingID, let tile = tiles[draggingID] { for layer in tile.layers { layer.isHidden = true } }

        updateInsertionMarker(geometry: geometry)
    }

    private func updateInsertionMarker(geometry: [DockLayout.Tile]) {
        guard let insertionIndex, model.isEditing || draggingID != nil || !model.dock.isLocked || model.tiles.isEmpty else {
            insertionMarker.opacity = 0
            return
        }
        // A line in the opened gap, spanning the icon height.
        var m: CGFloat
        if insertionIndex < geometry.count {
            m = geometry[insertionIndex].center - geometry[insertionIndex].width * geometry[insertionIndex].scale / 2 - metrics.gap - metrics.tile / 2
        } else if let last = geometry.last {
            m = last.center + last.width * last.scale / 2 + metrics.gap + metrics.tile / 2
        } else {
            m = metrics.plateLength / 2
        }
        let from = metrics.point(m: m, c: metrics.iconBase)
        let to = metrics.point(m: m, c: metrics.iconBase + metrics.tile)
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        insertionMarker.path = path
        insertionMarker.opacity = 1
    }

    // MARK: Pointer and magnification

    /// The region where the pointer means "this dock": the plate and the strip
    /// above it where magnified icons rise.
    var interactiveRect: CGRect {
        if isCollapsed { return pillRect.insetBy(dx: -6, dy: -6) }
        let plate = metrics.plateRect
        let reach = metrics.openOverflow
        let grown: CGRect
        switch metrics.edge {
        case .bottom: grown = CGRect(x: plate.minX, y: plate.minY, width: plate.width, height: plate.height + reach)
        case .top: grown = CGRect(x: plate.minX, y: plate.minY - reach, width: plate.width, height: plate.height + reach)
        case .left: grown = CGRect(x: plate.minX, y: plate.minY, width: plate.width + reach, height: plate.height)
        case .right: grown = CGRect(x: plate.minX - reach, y: plate.minY, width: plate.width + reach, height: plate.height)
        }
        // Magnified rows may stick out past either end a little.
        let slack = metrics.endOverflow
        return metrics.isHorizontal ? grown.insetBy(dx: -slack, dy: 0) : grown.insetBy(dx: 0, dy: -slack)
    }

    /// Called with the pointer position in this view's coordinates, or `nil`
    /// when the pointer has left the dock.
    func setPointer(_ p: CGPoint?) {
        let inside = p.map { interactiveRect.contains($0) } ?? false
        pointer = inside ? p : nil
        guard !isCollapsed else { setHover(nil); return }

        if let p, inside {
            pointerM = metrics.mainCoordinate(of: p)
            strengthTarget = 1
            lightTarget = p
        } else {
            strengthTarget = 0
            lightTarget = nil
        }
        pointerDirty = true
        startLink()
    }

    private func updateHover() {
        guard pointer != nil, let p = pointer else { setHover(nil); return }
        let cross = metrics.crossCoordinate(of: p)
        var found: UUID?
        if cross >= 0, let index = DockLayout.hitIndex(at: pointerM, tiles: layoutTiles), index < layoutIDs.count {
            let id = layoutIDs[index]
            if let tile = tiles[id], tile.model.item.kind != .separator {
                let scaled = metrics.tile * layoutTiles[index].scale
                if cross <= metrics.iconBase + scaled + 4 { found = id }
            }
        }
        setHover(found)
    }

    private func setHover(_ id: UUID?) {
        guard id != hoverID else { return }
        hoverID = id
        if let id, let tile = tiles[id], let rect = visualRect(of: id) {
            delegate?.dockContent(self, hover: tile.model, screenRect: screenRect(fromViewRect: rect))
        } else {
            delegate?.dockContent(self, hover: nil, screenRect: nil)
        }
    }

    func visualRect(of id: UUID) -> NSRect? {
        guard let index = layoutIDs.firstIndex(of: id), index < layoutTiles.count else { return nil }
        let g = layoutTiles[index]
        let size = metrics.tile * g.scale
        let start = metrics.point(m: g.center - size / 2, c: metrics.iconBase)
        let end = metrics.point(m: g.center + size / 2, c: metrics.iconBase + size)
        return NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    func screenRect(fromViewRect rect: NSRect) -> NSRect {
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    // MARK: Display link (easing only)

    private func startLink() {
        guard link == nil, window != nil else { return }
        let newLink = displayLink(target: self, selector: #selector(step(_:)))
        newLink.add(to: .main, forMode: .common)
        lastLinkTime = 0
        link = newLink
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ sender: CADisplayLink) {
        let now = sender.timestamp
        let dt = lastLinkTime == 0 ? 1.0 / 60.0 : min(now - lastLinkTime, 1.0 / 20.0)
        lastLinkTime = now

        // A critically damped spring: reaches the target without overshoot and
        // retargets smoothly if the pointer leaves and returns mid-flight.
        var easing = false
        if strength != strengthTarget || strengthVelocity != 0 {
            let response: CGFloat = strengthTarget > strength ? 0.11 : 0.16
            let omega = 2 * .pi / response
            let delta = strength - strengthTarget
            let acceleration = -omega * omega * delta - 2 * omega * strengthVelocity
            strengthVelocity += acceleration * CGFloat(dt)
            strength += strengthVelocity * CGFloat(dt)
            if abs(strength - strengthTarget) < 0.002 && abs(strengthVelocity) < 0.01 {
                strength = strengthTarget
                strengthVelocity = 0
            } else {
                easing = true
            }
            strength = min(max(strength, 0), 1.02)
        }

        if pointerDirty || easing {
            pointerDirty = false
            layoutTilesNow()
            updateHover()
            surface.setLight(at: lightTarget)
        }
        // Nothing left to animate: stop asking for frames until the pointer moves.
        if !easing && !pointerDirty { stopLink() }
    }

    // MARK: Collapse

    private var pillWidth: CGFloat {
        let glyph = model.dock.collapseGlyph
        return glyph.isEmpty ? 54 : max(54, CGFloat(glyph.count) * 11 + 30)
    }

    var pillRect: CGRect {
        let plate = metrics.plateRect
        let w = metrics.isHorizontal ? pillWidth : 22
        let h = metrics.isHorizontal ? 22 : pillWidth
        switch metrics.edge {
        case .bottom: return CGRect(x: plate.midX - w / 2, y: plate.minY, width: w, height: h)
        case .top: return CGRect(x: plate.midX - w / 2, y: plate.maxY - h, width: w, height: h)
        case .left: return CGRect(x: plate.minX, y: plate.midY - h / 2, width: w, height: h)
        case .right: return CGRect(x: plate.maxX - w, y: plate.midY - h / 2, width: w, height: h)
        }
    }

    private func pillTheme(_ theme: GlassTheme) -> GlassTheme {
        var pill = theme
        pill.capsule = true
        pill.shadowRadius = theme.shadowRadius * 0.6
        pill.glowIntensity = theme.glowIntensity * 0.6
        return pill
    }

    private func positionPillGlyph() {
        pillGlyph.bounds = CGRect(x: 0, y: 0, width: pillRect.width, height: pillRect.height)
        pillGlyph.position = CGPoint(x: pillRect.midX, y: pillRect.midY)
        pillGlyph.contentsGravity = .center
        pillGlyph.contentsScale = scale
        let glyph = model.dock.collapseGlyph
        let pixels = Int(max(pillRect.width, pillRect.height) * scale)
        if glyph.isEmpty {
            let name: String
            switch metrics.edge { case .bottom: name = "chevron.compact.up"; case .top: name = "chevron.compact.down"
            case .left: name = "chevron.compact.right"; case .right: name = "chevron.compact.left" }
            pillGlyph.contents = TileImages.shared.symbol(name, fill: 0.34, color: context.foreground.withAlphaComponent(0.8), pixels: max(pixels, 64), weight: .semibold)
            pillGlyph.contentsGravity = .resizeAspect
            pillGlyph.bounds = CGRect(x: 0, y: 0, width: 28, height: 22)
            if !metrics.isHorizontal { pillGlyph.bounds = CGRect(x: 0, y: 0, width: 22, height: 28) }
        } else {
            pillGlyph.contents = TileImages.shared.text(glyph, color: context.foreground.withAlphaComponent(0.85), height: 22, scale: scale)
            pillGlyph.contentsGravity = .center
        }
    }

    /// Switches between the full plate and the small button, with a crossfade
    /// the render server runs by itself.
    func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        if collapsed && model.dock.collapseMode.collapsesToButton && pillSurface == nil {
            let view = GlassSurfaceView(theme: pillTheme(model.theme), backdrop: .behindWindow)
            view.frame = bounds
            addSubview(view, positioned: .below, relativeTo: tilesHost)
            view.wantsLayer = true
            pillSurface = view
            tilesHost.layer?.addSublayer(pillGlyph)
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        let usesPill = model.dock.collapseMode.collapsesToButton
        let duration = animated ? 0.22 : 0
        pointer = nil
        strengthTarget = 0
        setHover(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.allowsImplicitAnimation = true
            surface.animator().alphaValue = collapsed ? 0 : 1
            pillSurface?.animator().alphaValue = collapsed && usesPill ? 1 : 0
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        for tile in tiles.values { for layer in tile.layers { layer.opacity = collapsed ? 0 : (layer === tile.host && tile.model.item.kind == .file && context.dimsNonRunning && !tile.model.isRunning ? 0.55 : 1) } }
        pillGlyph.opacity = collapsed && usesPill ? 1 : 0
        placeholder.isHidden = collapsed || !model.tiles.isEmpty
        CATransaction.commit()
        if collapsed { strength = 0; strengthVelocity = 0; stopLink(); layoutTilesNow() }
    }

    // MARK: Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return interactiveRect.contains(local) ? self : nil
    }

    func tileID(at point: CGPoint) -> UUID? {
        guard !isCollapsed else { return nil }
        let m = metrics.mainCoordinate(of: point)
        let cross = metrics.crossCoordinate(of: point)
        guard cross >= -2, let index = DockLayout.hitIndex(at: m, tiles: layoutTiles), index < layoutIDs.count else { return nil }
        let id = layoutIDs[index]
        guard tiles[id]?.model.item.kind != .separator else { return nil }
        let scaled = metrics.tile * layoutTiles[index].scale
        return cross <= metrics.iconBase + scaled + 4 ? id : nil
    }

    func tileModel(_ id: UUID?) -> TileModel? { id.flatMap { tiles[$0]?.model } }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouseDownPoint = p
        didStartDrag = false
        if isCollapsed { mouseDownTile = nil; return }
        if model.isEditing, let id = minusTile(at: p) { delegate?.dockContent(self, remove: id); mouseDownTile = nil; return }
        mouseDownTile = tileID(at: p)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = mouseDownTile, !didStartDrag else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - mouseDownPoint.x, p.y - mouseDownPoint.y) > 5 else { return }
        guard canReorder else { return }
        didStartDrag = true
        beginTileDrag(id: id, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownTile = nil; didStartDrag = false }
        guard !didStartDrag else { return }
        let p = convert(event.locationInWindow, from: nil)
        if isCollapsed {
            if pillRect.insetBy(dx: -4, dy: -4).contains(p) { delegate?.dockContentDidClickPill(self) }
            return
        }
        guard let id = tileID(at: p), id == mouseDownTile, let tile = tiles[id], let rect = visualRect(of: id) else { return }
        delegate?.dockContent(self, didClick: tile.model, rect: rect)
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard !isCollapsed || pillRect.contains(p) else { return }
        let id = tileID(at: p)
        let rect = id.flatMap { visualRect(of: $0) } ?? metrics.plateRect
        if let menu = delegate?.dockContent(self, menuFor: id.flatMap { tiles[$0]?.model }, rect: rect) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let id = tileID(at: p), let tile = tiles[id] else { super.scrollWheel(with: event); return }
        delegate?.dockContent(self, scrolled: tile.model, delta: event.scrollingDeltaY)
    }

    private func minusTile(at point: CGPoint) -> UUID? {
        for (id, tile) in tiles where !tile.minus.isHidden {
            let frame = CGRect(x: tile.minus.position.x - 11, y: tile.minus.position.y - 11, width: 22, height: 22)
            if frame.contains(point) { return id }
        }
        return nil
    }

    /// Reordering is for the user's own tiles, in an unlocked dock or in Edit mode.
    var canReorder: Bool {
        !model.isDerived && model.dock.contentMode == .manual && (model.isEditing || !model.dock.isLocked)
    }

    /// Whether files can be dropped on the plate to pin them.
    var canPin: Bool {
        !model.isDerived && model.dock.contentMode == .manual
            && (model.isEditing || !model.dock.isLocked || model.tiles.isEmpty)
    }

    // MARK: Drop feedback

    func showDropRing(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        dropRing.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    func highlightTile(_ id: UUID?) {
        guard id != highlightedTile else { return }
        if let old = highlightedTile, let tile = tiles[old] { tile.setDropHighlight(false, context: context) }
        highlightedTile = id
        if let id, let tile = tiles[id] { tile.setDropHighlight(true, context: context) }
    }

    func setInsertion(_ index: Int?) {
        guard index != insertionIndex else { return }
        insertionIndex = index
        // The gap opens with the pointer pinned to the dragged position so the
        // row slides apart under it.
        strengthTarget = index == nil && pointer == nil ? 0 : max(strengthTarget, 0)
        layoutTilesNow()
    }

    /// Where a pointer position falls among the *other* tiles, for drag-to-reorder
    /// and drop-to-pin.
    func insertionIndexForDrag(at point: CGPoint) -> Int {
        let m = metrics.mainCoordinate(of: point)
        // Positions measured against the resting layout, so the gap doesn't chase itself.
        var rest = layoutInput().0
        rest.pointer = nil
        rest.gapIndex = nil
        rest.strength = 0
        let resting = DockLayout.compute(rest)
        return DockLayout.insertionIndex(at: m, tiles: resting)
    }

    func idsExcludingDragged() -> [UUID] { model.tiles.map(\.id).filter { $0 != draggingID } }

    // MARK: Launch bounce

    func setLaunching(_ id: UUID, _ launching: Bool) {
        guard let host = tiles[id]?.host else { return }
        if launching {
            let animation = CAKeyframeAnimation(keyPath: "position")
            let hop = metrics.tile * 0.35
            let up = NSValue(point: CGPoint(x: metrics.inward.dx * hop, y: metrics.inward.dy * hop))
            let low = NSValue(point: CGPoint(x: metrics.inward.dx * hop * 0.3, y: metrics.inward.dy * hop * 0.3))
            animation.values = [NSValue(point: .zero), up, NSValue(point: .zero), low, NSValue(point: .zero)]
            animation.keyTimes = [0, 0.3, 0.55, 0.75, 1]
            animation.duration = 0.9
            animation.isAdditive = true
            animation.repeatCount = .infinity
            host.add(animation, forKey: "launchBounce")
        } else {
            host.removeAnimation(forKey: "launchBounce")
        }
    }

    // MARK: Window lifecycle

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        apply(model: model, metrics: metrics)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        surface.refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLink() }
    }
}

private extension DockMetrics {
    func restRowLengthExcludingDragged(widths: [CGFloat], gap: CGFloat) -> CGFloat {
        widths.isEmpty ? 0 : widths.reduce(0, +) + CGFloat(widths.count - 1) * gap
    }
}
