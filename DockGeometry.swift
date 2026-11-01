import CoreGraphics

/// Edge-relative geometry for one dock.
///
/// Everything is described on two axes so one piece of maths serves all four
/// screen edges: the *main* axis runs along the dock (left→right for top and
/// bottom docks, top→bottom for left and right ones) and the *cross* axis
/// runs away from the screen edge the dock is pinned to. `point(m:c:)` is the
/// one place that turns that into view coordinates (non-flipped, origin
/// bottom-left).
///
/// The window is deliberately larger than the visible plate: it carries room
/// for the shadow and glow (which used to be clipped at the window's edge,
/// leaving a visible rectangular boundary around the dock), for tiles to grow
/// past the plate when magnified, and for lift effects.
struct DockMetrics: Equatable {
    var edge: DockEdge
    var count: Int
    var tile: CGFloat
    var maxTile: CGFloat
    var gap: CGFloat
    var padding: CGFloat
    /// Room reserved between the plate's edge side and the icons for the
    /// running indicator.
    var indicatorGutter: CGFloat
    var labelGutter: CGFloat
    var shadowMargin: CGFloat
    /// Extra room beyond the magnified size for lift and glow.
    var liftAllowance: CGFloat
    /// The plate never gets shorter than this (an empty dock still has to hold
    /// its "drop apps here" hint).
    var minPlateLength: CGFloat
    /// Edge-to-edge docks stretch the plate to this length.
    var stretchLength: CGFloat?
    /// Combined width of every non-tile gap in the row (separators are narrower
    /// than tiles, so the row isn't simply `count × tile`).
    var restRowLength: CGFloat

    var isHorizontal: Bool { edge.isHorizontal }

    var plateLength: CGFloat { max(restRowLength + 2 * padding, minPlateLength, stretchLength ?? 0) }
    var plateBreadth: CGFloat { padding + indicatorGutter + labelGutter + tile + padding }

    /// How far tiles can reach past the plate on its open side.
    var openOverflow: CGFloat { max(maxTile - tile, 0) + liftAllowance }
    /// How far the row can extend past either end of the plate while magnified.
    var endOverflow: CGFloat { max(maxTile - tile, 0) * 0.6 + tile * 0.1 }

    var windowLength: CGFloat { plateLength + 2 * endOverflow + 2 * shadowMargin }
    var windowBreadth: CGFloat { plateBreadth + openOverflow + 2 * shadowMargin }

    var windowSize: CGSize {
        isHorizontal ? CGSize(width: windowLength, height: windowBreadth)
                     : CGSize(width: windowBreadth, height: windowLength)
    }

    /// The visible plate, in the window's own coordinates.
    var plateRect: CGRect {
        switch edge {
        case .bottom:
            return CGRect(x: shadowMargin + endOverflow, y: shadowMargin, width: plateLength, height: plateBreadth)
        case .top:
            return CGRect(x: shadowMargin + endOverflow, y: windowBreadth - shadowMargin - plateBreadth,
                          width: plateLength, height: plateBreadth)
        case .left:
            return CGRect(x: shadowMargin, y: shadowMargin + endOverflow, width: plateBreadth, height: plateLength)
        case .right:
            return CGRect(x: windowBreadth - shadowMargin - plateBreadth, y: shadowMargin + endOverflow,
                          width: plateBreadth, height: plateLength)
        }
    }

    /// Maps (distance along the dock from the plate's start, distance from the
    /// screen edge) to a point in the window.
    func point(m: CGFloat, c: CGFloat) -> CGPoint {
        let plate = plateRect
        switch edge {
        case .bottom: return CGPoint(x: plate.minX + m, y: plate.minY + c)
        case .top: return CGPoint(x: plate.minX + m, y: plate.maxY - c)
        case .left: return CGPoint(x: plate.minX + c, y: plate.maxY - m)
        case .right: return CGPoint(x: plate.maxX - c, y: plate.maxY - m)
        }
    }

    /// The inverse for the main axis: where along the dock a window point is.
    func mainCoordinate(of p: CGPoint) -> CGFloat {
        let plate = plateRect
        return isHorizontal ? p.x - plate.minX : plate.maxY - p.y
    }

    /// Distance from the screen edge side of the plate, for a window point.
    func crossCoordinate(of p: CGPoint) -> CGFloat {
        let plate = plateRect
        switch edge {
        case .bottom: return p.y - plate.minY
        case .top: return plate.maxY - p.y
        case .left: return p.x - plate.minX
        case .right: return plate.maxX - p.x
        }
    }

    /// Where an icon's edge-facing face sits across the plate.
    var iconBase: CGFloat { padding + indicatorGutter + labelGutter }

    /// The anchor that keeps a scaled tile pinned to the edge side.
    var tileAnchor: CGPoint {
        switch edge {
        case .bottom: return CGPoint(x: 0.5, y: 0)
        case .top: return CGPoint(x: 0.5, y: 1)
        case .left: return CGPoint(x: 0, y: 0.5)
        case .right: return CGPoint(x: 1, y: 0.5)
        }
    }

    /// Unit vector pointing from the screen edge into the screen.
    var inward: CGVector {
        switch edge {
        case .bottom: return CGVector(dx: 0, dy: 1)
        case .top: return CGVector(dx: 0, dy: -1)
        case .left: return CGVector(dx: 1, dy: 0)
        case .right: return CGVector(dx: -1, dy: 0)
        }
    }
}
