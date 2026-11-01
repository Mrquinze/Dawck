import Foundation
import AppKit
import Combine

/// One named group of menu bar items that can be collapsed on its own.
///
/// A cluster is not a list of apps — it can't be. Nothing in the public API
/// lets one app enumerate or move another app's status item; that's what
/// Bartender needs Accessibility for. What a cluster owns instead is a
/// *boundary*: a status item of Dawck's own that the user drags their other
/// menu bar icons around with Command-drag. Collapsing the cluster widens that
/// boundary item until everything to its left is pushed off the screen.
struct MenuBarCluster: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "Cluster"
    /// SF Symbol shown as the cluster's handle in the menu bar.
    var symbol: String = "chevron.left.2"
    var isCollapsed: Bool = false
    /// Seconds after revealing before the cluster collapses again. 0 = stay open
    /// until toggled.
    var autoCollapseDelay: Double = 0
    /// Collapse this cluster whenever Dawck launches, so a machine that reboots
    /// comes back tidy instead of in whatever state it was left in.
    var collapsesAtLaunch: Bool = true

    init(
        id: UUID = UUID(),
        name: String = "Cluster",
        symbol: String = "chevron.left.2",
        isCollapsed: Bool = false,
        autoCollapseDelay: Double = 0,
        collapsesAtLaunch: Bool = true
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.isCollapsed = isCollapsed
        self.autoCollapseDelay = autoCollapseDelay
        self.collapsesAtLaunch = collapsesAtLaunch
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, isCollapsed, autoCollapseDelay, collapsesAtLaunch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MenuBarCluster()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? d.symbol
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? d.isCollapsed
        autoCollapseDelay = try c.decodeIfPresent(Double.self, forKey: .autoCollapseDelay) ?? d.autoCollapseDelay
        collapsesAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .collapsesAtLaunch) ?? d.collapsesAtLaunch
    }

    /// Suggested handles, so a new cluster doesn't default to looking like
    /// every other one.
    static let symbolChoices = [
        "chevron.left.2", "circle.grid.2x2", "hammer", "message",
        "bolt", "cloud", "waveform", "cube", "flag", "tag"
    ]
}

/// Persists clusters and their order. Order matters here in a way it doesn't
/// for docks: clusters sit left to right in the menu bar, and collapsing one
/// necessarily hides everything further left (see `MenuBarClusterManager`).
final class MenuBarClusterStore: ObservableObject {
    @Published var clusters: [MenuBarCluster] { didSet { save() } }

    private static let defaultsKey = "menuBarClusters"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([MenuBarCluster].self, from: data) {
            clusters = decoded
        } else {
            clusters = []
        }

        // Applied once at startup rather than persisted back, so the stored
        // `isCollapsed` still reflects the user's last manual choice.
        for index in clusters.indices where clusters[index].collapsesAtLaunch {
            clusters[index].isCollapsed = true
        }
    }

    @discardableResult
    func add() -> MenuBarCluster {
        let cluster = MenuBarCluster(
            name: "Cluster \(clusters.count + 1)",
            symbol: MenuBarCluster.symbolChoices[clusters.count % MenuBarCluster.symbolChoices.count]
        )
        clusters.append(cluster)
        return cluster
    }

    func update(_ cluster: MenuBarCluster) {
        guard let index = clusters.firstIndex(where: { $0.id == cluster.id }) else { return }
        guard clusters[index] != cluster else { return }
        clusters[index] = cluster
    }

    func remove(_ cluster: MenuBarCluster) {
        clusters.removeAll { $0.id == cluster.id }
    }

    func toggle(_ id: UUID) {
        guard let index = clusters.firstIndex(where: { $0.id == id }) else { return }
        clusters[index].isCollapsed.toggle()
    }

    func setCollapsed(_ collapsed: Bool, for id: UUID) {
        guard let index = clusters.firstIndex(where: { $0.id == id }) else { return }
        guard clusters[index].isCollapsed != collapsed else { return }
        clusters[index].isCollapsed = collapsed
    }

    func revealAll() {
        for index in clusters.indices { clusters[index].isCollapsed = false }
    }

    func collapseAll() {
        for index in clusters.indices { clusters[index].isCollapsed = true }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(clusters) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
