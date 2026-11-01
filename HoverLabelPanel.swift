import AppKit

/// The name bubble that appears above (or beside) the tile under the pointer,
/// like the real Dock's. It replaces the system tooltip, which waits about a
/// second, looks like a tooltip, and was a large part of why hovering felt slow.
final class HoverLabelPanel: NSPanel {
    static let label = HoverLabelPanel(isToast: false)
    static let toast = HoverLabelPanel(isToast: true)

    /// A flat translucent plate rather than a blurred one. A blurred window has
    /// to be re-sampled by the window server every time it moves, and moving
    /// from tile to tile is all this window does — it was the one thing that
    /// still dropped frames during a hover sweep.
    private let box = NSView()
    fileprivate let field = NSTextField(labelWithString: "")
    private let isToast: Bool
    private var hideWork: DispatchWorkItem?
    fileprivate var maskSize: CGSize = .zero

    private static let stretchableMask: NSImage = {
        let image = PlateShape.maskImage(size: NSSize(width: 29, height: 29), radius: 14.5, continuous: true)
        image.capInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        image.resizingMode = .stretch
        return image
    }()

    private init(isToast: Bool) {
        self.isToast = isToast
        super.init(contentRect: NSRect(x: 0, y: 0, width: 80, height: 26),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        // No window shadow: it is recomputed from the window's shape on every
        // resize, which is exactly what happens as the label follows the pointer.
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        alphaValue = 0

        box.wantsLayer = true
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 0.5
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = isToast ? 3 : 1
        field.drawsBackground = false
        contentView = box
        box.addSubview(field)
    }

    private static var warmed = false

    /// Creating a window the first time it is needed costs tens of
    /// milliseconds — enough to drop several frames in the middle of the first
    /// sweep across a dock. Doing it once, off screen, at launch moves that cost
    /// to a moment nobody is watching.
    static func warmUp() {
        guard !warmed else { return }
        warmed = true
        for panel in [label, toast] {
            panel.field.stringValue = "Dawck"
            panel.setFrame(NSRect(x: -20_000, y: -20_000, width: 80, height: 26), display: true)
            panel.alphaValue = 0.01
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                panel.orderOut(nil)
                panel.alphaValue = 0
                panel.maskSize = .zero
            }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `text` next to `rect` (screen coordinates), on the side facing into the screen.
    func show(_ text: String, near rect: NSRect, edge: DockEdge, appearance: NSAppearance?, lifetime: TimeInterval? = nil) {
        hideWork?.cancel()
        let dark = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map {
            $0 == .darkAqua || $0 == .vibrantDark
        } ?? true
        box.layer?.backgroundColor = (dark ? NSColor(white: 0.13, alpha: 0.9) : NSColor(white: 0.97, alpha: 0.92)).cgColor
        box.layer?.borderColor = (dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.12)).cgColor
        field.textColor = isToast ? (dark ? .white : .black) : (dark ? .white : .black)
        field.stringValue = text
        let maxWidth: CGFloat = isToast ? 340 : 280
        field.preferredMaxLayoutWidth = maxWidth
        let natural = field.sizeThatFits(NSSize(width: maxWidth, height: 200))
        let size = NSSize(width: min(max(natural.width + 22, 36), maxWidth + 22), height: natural.height + (isToast ? 14 : 10))
        field.frame = NSRect(x: 11, y: (size.height - natural.height) / 2, width: size.width - 22, height: natural.height)
        if size != maskSize {
            maskSize = size
            setContentSize(size)
            box.layer?.cornerRadius = min(size.height / 2, 14)
        }

        var origin: NSPoint
        switch edge {
        case .bottom: origin = NSPoint(x: rect.midX - size.width / 2, y: rect.maxY + 8)
        case .top: origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
        case .left: origin = NSPoint(x: rect.maxX + 10, y: rect.midY - size.height / 2)
        case .right: origin = NSPoint(x: rect.minX - size.width - 10, y: rect.midY - size.height / 2)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main {
            let bounds = screen.frame.insetBy(dx: 6, dy: 6)
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        }
        setFrameOrigin(origin)

        if !isVisible { orderFrontRegardless() }
        if alphaValue < 1 {
            // A short fade in, started from the label's own alpha so a label
            // that is already showing just moves.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.07
                animator().alphaValue = 1
            }
        }
        if let lifetime {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: work)
        }
    }

    /// Hiding is instant and leaves the window where it is. Ordering a window
    /// out and back in is the expensive part, so it only happens after the label
    /// has been unused for a while.
    func hide() {
        hideWork?.cancel()
        guard isVisible else { return }
        alphaValue = 0
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.alphaValue < 0.01 else { return }
            self.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}
