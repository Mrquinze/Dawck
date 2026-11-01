import AppKit
import QuartzCore

extension DockContentView {
    /// A brief springy entrance: each tile rises from the screen edge and fades
    /// in, a few milliseconds apart. Run by the render server, not the main thread.
    func playEntrance() {
        let inward = metrics.inward
        let travel = metrics.tile * 0.45
        let start = CACurrentMediaTime()
        for (index, tile) in model.tiles.enumerated() {
            guard let host = tiles[tile.id]?.host else { continue }
            let delay = start + Double(index) * 0.018

            let rise = CASpringAnimation(keyPath: "position")
            rise.isAdditive = true
            rise.fromValue = NSValue(point: CGPoint(x: -inward.dx * travel, y: -inward.dy * travel))
            rise.toValue = NSValue(point: .zero)
            rise.mass = 1
            rise.stiffness = 260
            rise.damping = 17
            rise.duration = min(rise.settlingDuration, 0.7)
            rise.beginTime = delay
            rise.fillMode = .backwards

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = host.opacity
            fade.duration = 0.18
            fade.beginTime = delay
            fade.fillMode = .backwards

            host.add(rise, forKey: "entranceRise")
            host.add(fade, forKey: "entranceFade")
        }
    }
}
