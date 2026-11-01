import AppKit

/// The borderless window one dock lives in. It joins every Space and floats
/// above normal windows, but is otherwise an ordinary window owned by Dawck.
///
/// It is larger than the dock itself — room for the shadow, glow and magnified
/// icons — and mostly empty, so it ignores mouse events except while the
/// pointer is over the part that is actually the dock. That is what lets
/// clicks fall through to whatever is underneath the transparent margin.
final class SecondaryDockPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The glass draws its own shadow so the theme controls it; a window
        // shadow would outline the window's rectangle instead of the plate.
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Dock windows deliberately reach past the screen edge (their shadow
    /// margin does), which AppKit would otherwise pull back.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
