import CoreGraphics

/// Where each tile sits and how large it is, for a given pointer position.
///
/// A pure function of its inputs — no views, no animation state — so the
/// maths can be tested directly, and so animation is just "feed it a number
/// that changes over time".
///
/// The behaviour follows the real Dock: icons near the pointer grow along a
/// smooth bump, neighbours slide apart to make room, and the row is anchored
/// so the icon under the pointer *stays* under it as you move along (a row
/// that merely grew about its centre would drift out from under the cursor).
enum DockLayout {

    struct Input {
        var widths: [CGFloat]
        /// Whether each tile takes part in magnification (spacers don't).
        var magnifies: [Bool]
        var base: CGFloat
        var maxSize: CGFloat
        var gap: CGFloat
        var padding: CGFloat
        /// Pointer position along the main axis from the plate's start, if any.
        var pointer: CGFloat?
        /// 0…1, how far magnification has eased in.
        var strength: CGFloat
        /// Falloff radius in tile widths.
        var spread: CGFloat = 2.4
        /// Opens a gap before this tile (an insertion marker while dragging).
        var gapIndex: Int?
        var gapWidth: CGFloat = 0
        /// How far the magnified row may extend past the plate ends.
        var endSlack: CGFloat = 0
        var plateLength: CGFloat = 0
    }

    struct Tile: Equatable {
        /// Centre along the main axis, from the plate's start.
        var center: CGFloat
        /// 1 at rest; grows towards `maxSize / base`.
        var scale: CGFloat
        /// 0…1 closeness to the pointer, shared by every hover style.
        var proximity: CGFloat
        var width: CGFloat
    }

    /// The bump: 1 at the pointer, falling smoothly to 0 — with zero slope at
    /// both ends, so neighbours join in without a visible kink.
    static func falloff(distance: CGFloat, radius: CGFloat) -> CGFloat {
        guard radius > 0, distance < radius else { return 0 }
        let t = distance / radius
        let v = 1 - t * t
        return v * v
    }

    static func restCenters(_ input: Input) -> [CGFloat] {
        var centers: [CGFloat] = []
        var cursor = input.padding
        for (index, width) in input.widths.enumerated() {
            if input.gapIndex == index { cursor += input.gapWidth + input.gap }
            centers.append(cursor + width / 2)
            cursor += width + input.gap
        }
        return centers
    }

    static func compute(_ input: Input) -> [Tile] {
        let count = input.widths.count
        guard count > 0 else { return [] }
        let rest = restCenters(input)
        let magnifiedRatio = input.base > 0 ? max(input.maxSize / input.base, 1) : 1
        let radius = input.spread * input.base

        let active = input.pointer != nil && input.strength > 0.0001

        var scales = [CGFloat](repeating: 1, count: count)
        var proximity = [CGFloat](repeating: 0, count: count)
        if active, let pointer = input.pointer {
            for index in 0..<count {
                let f = falloff(distance: abs(pointer - rest[index]), radius: radius)
                proximity[index] = f * input.strength
                if input.magnifies[index] {
                    scales[index] = 1 + (magnifiedRatio - 1) * f * input.strength
                }
            }
        }

        // Left edge of each tile once neighbours have been pushed apart.
        var lefts = [CGFloat](repeating: 0, count: count)
        var cursor = input.padding
        for index in 0..<count {
            if input.gapIndex == index { cursor += input.gapWidth + input.gap }
            lefts[index] = cursor
            cursor += input.widths[index] * scales[index] + input.gap
        }

        // Anchor: keep the point of the row that was under the pointer at rest
        // under the pointer now.
        var shift: CGFloat = 0
        if active, let pointer = input.pointer {
            var index = 0
            while index < count - 1 && pointer > rest[index] + input.widths[index] / 2 + input.gap / 2 { index += 1 }
            let restLeft = rest[index] - input.widths[index] / 2
            let fraction = input.widths[index] > 0
                ? min(max((pointer - restLeft) / input.widths[index], 0), 1)
                : 0.5
            let mapped = lefts[index] + fraction * input.widths[index] * scales[index]
            shift = (pointer - mapped) * input.strength
            // Keep the row from sliding far past the ends of the plate.
            let first = lefts[0] + shift
            let last = lefts[count - 1] + input.widths[count - 1] * scales[count - 1] + shift
            if first < -input.endSlack { shift += -input.endSlack - first }
            if last > input.plateLength + input.endSlack { shift -= last - (input.plateLength + input.endSlack) }
        }

        return (0..<count).map { index in
            let width = input.widths[index] * scales[index]
            return Tile(center: lefts[index] + shift + width / 2,
                        scale: scales[index],
                        proximity: proximity[index],
                        width: input.widths[index])
        }
    }

    /// The insertion index whose gap a pointer position falls into, for
    /// drag-to-reorder and drop-to-pin.
    static func insertionIndex(at pointer: CGFloat, tiles: [Tile]) -> Int {
        for (index, tile) in tiles.enumerated() where pointer < tile.center { return index }
        return tiles.count
    }

    /// The index of the tile whose extent contains `pointer`, if any.
    static func hitIndex(at pointer: CGFloat, tiles: [Tile]) -> Int? {
        for (index, tile) in tiles.enumerated() {
            let half = tile.width * tile.scale / 2
            if pointer >= tile.center - half && pointer <= tile.center + half { return index }
        }
        return nil
    }
}
