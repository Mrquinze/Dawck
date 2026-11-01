import SwiftUI
import AppKit

/// A small, static picture of a theme, for the preset grid and lists. It uses
/// the dock's own renderer with a flat stand-in for the blur, so a screenful of
/// swatches costs a handful of bitmaps rather than a screenful of live blurs.
struct GlassSwatch: NSViewRepresentable {
    let theme: GlassTheme
    /// Shrinks radii and strokes for small thumbnails.
    var scale: CGFloat = 1

    func makeNSView(context: Context) -> SwatchHost { SwatchHost(theme: theme, scale: scale) }

    func updateNSView(_ view: SwatchHost, context: Context) {
        view.surface.detailScale = scale
        view.surface.setTheme(theme)
    }

    final class SwatchHost: NSView {
        let surface: GlassSurfaceView

        init(theme: GlassTheme, scale: CGFloat) {
            surface = GlassSurfaceView(theme: theme, backdrop: .simulated, detailScale: scale)
            super.init(frame: .zero)
            wantsLayer = true
            addSubview(surface)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            surface.frame = bounds
            surface.plateFrame = bounds.insetBy(dx: 1, dy: 1)
        }
    }
}
