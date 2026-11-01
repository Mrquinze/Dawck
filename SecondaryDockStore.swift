import Foundation
import Combine

/// Persists the user's dock configurations to UserDefaults as JSON. This is
/// Dawck's own storage, entirely separate from `com.apple.dock` — these docks
/// are custom panels the app renders, not part of the real Dock.
final class SecondaryDockStore: ObservableObject {
    @Published var docks: [SecondaryDock] {
        didSet { save() }
    }

    static let defaultsKey = "secondaryDocks"

    init() {
        LegacyMigration.ensure()
        docks = Self.load()
    }

    static func load() -> [SecondaryDock] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([SecondaryDock].self, from: data)
        } catch {
            // Deliberately does not clear the stored data: a decode failure is
            // far more likely to be a bug here than genuine corruption, and
            // wiping it would turn a recoverable bug into permanent data loss.
            NSLog("Dawck: failed to decode secondaryDocks, leaving stored data on disk untouched: \(error)")
            return []
        }
    }

    private let writer = DebouncedWriter()

    /// Writes are coalesced: editing a slider changes `docks` dozens of times a
    /// second, and encoding and writing the whole configuration each time was
    /// a large part of why settings felt laggy.
    private func save() {
        writer.schedule { [docks] in
            guard let data = try? JSONEncoder().encode(docks) else { return }
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func flush() { writer.flush() }

    /// Replaces every dock at once — used when applying a profile, where
    /// assigning `docks` per-item would fire a save and a panel reconcile for
    /// each one.
    func replaceAll(with docks: [SecondaryDock]) {
        self.docks = docks
    }

    @discardableResult
    func addDock() -> SecondaryDock {
        var dock = SecondaryDock(name: "Dock \(docks.count + 1)")
        dock.isLocked = true
        docks.append(dock)
        return dock
    }

    /// A ready-made dock for the welcome tour: a few common apps that exist on
    /// this Mac, a clock, and the Trash — locked, so it stays as made until edited.
    @discardableResult
    func addStarterDock() -> SecondaryDock {
        var dock = SecondaryDock(name: "My Dock")
        let candidates = ["/System/Applications/Apps.app", "/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app",
                          "/System/Applications/Mail.app", "/System/Applications/Messages.app", "/System/Applications/Music.app",
                          "/System/Applications/Notes.app", "/System/Applications/Calendar.app", "/System/Applications/Utilities/Terminal.app"]
        var seen = Set<String>()
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            let name = (path as NSString).lastPathComponent
            if seen.insert(name).inserted { dock.items.append(DockItem(path: path)) }
        }
        dock.items.append(DockItem(kind: .separator))
        var clock = DockItem(kind: .widget); clock.widget = .clock
        dock.items.append(clock)
        dock.items.append(DockItem(kind: .trash))
        dock.isLocked = true
        docks.append(dock)
        return dock
    }

    func update(_ dock: SecondaryDock) {
        guard let index = docks.firstIndex(where: { $0.id == dock.id }) else { return }
        guard docks[index] != dock else { return }
        docks[index] = dock
    }

    func remove(_ dock: SecondaryDock) {
        docks.removeAll { $0.id == dock.id }
    }

    func duplicate(_ dock: SecondaryDock) {
        var copy = dock
        copy.id = UUID()
        copy.name = "\(dock.name) Copy"
        // Fresh tile identities too — two docks sharing item IDs would make
        // "remove this tile" ambiguous.
        copy.items = dock.items.map { item in
            var duplicated = item
            duplicated.id = UUID()
            return duplicated
        }
        docks.append(copy)
    }

    /// Reorders tiles within one dock, for drag-to-reorder in the panel itself.
    func moveItem(in dockID: UUID, from source: Int, to destination: Int) {
        guard let dockIndex = docks.firstIndex(where: { $0.id == dockID }) else { return }
        var items = docks[dockIndex].items
        guard items.indices.contains(source) else { return }
        // `destination` arrives as an insertion index computed against the list
        // *before* the removal, so it has to be shifted once the earlier
        // element is gone — otherwise dragging rightwards lands one slot short.
        let clamped = min(max(destination, 0), items.count)
        let item = items.remove(at: source)
        let target = clamped > source ? clamped - 1 : clamped
        items.insert(item, at: min(target, items.count))
        docks[dockIndex].items = items
    }

    /// Moves a tile to an insertion index measured against the list *before* the
    /// move (the form drag-and-drop produces).
    func moveItem(id: UUID, toInsertionIndex destination: Int, in dockID: UUID) {
        guard let dockIndex = docks.firstIndex(where: { $0.id == dockID }),
              let source = docks[dockIndex].items.firstIndex(where: { $0.id == id }) else { return }
        moveItem(in: dockID, from: source, to: destination)
    }

    /// Inserts tiles at `index`, skipping files the dock already holds.
    func insertItems(_ items: [DockItem], at index: Int, in dockID: UUID) {
        guard let dockIndex = docks.firstIndex(where: { $0.id == dockID }) else { return }
        var list = docks[dockIndex].items
        var position = min(max(index, 0), list.count)
        for item in items {
            if item.kind == .file, list.contains(where: { $0.kind == .file && $0.path == item.path }) { continue }
            guard list.count < 300 else { break }
            list.insert(item, at: position)
            position += 1
        }
        docks[dockIndex].items = list
    }

    /// Edits one dock in place.
    func mutate(_ dockID: UUID, _ change: (inout SecondaryDock) -> Void) {
        guard let index = docks.firstIndex(where: { $0.id == dockID }) else { return }
        var copy = docks[index]
        change(&copy)
        copy.sanitize()
        update(copy)
    }

    func appendItem(_ item: DockItem, to dockID: UUID) {
        guard let index = docks.firstIndex(where: { $0.id == dockID }) else { return }
        if item.kind == .file, docks[index].items.contains(where: { $0.kind == .file && $0.path == item.path }) {
            return
        }
        docks[index].items.append(item)
    }

    /// Replaces one tile in place — used by tiles that own mutable state of
    /// their own, like a tray gaining a staged file.
    func replaceItem(_ item: DockItem, in dockID: UUID) {
        guard let dockIndex = docks.firstIndex(where: { $0.id == dockID }) else { return }
        guard let itemIndex = docks[dockIndex].items.firstIndex(where: { $0.id == item.id }) else { return }
        guard docks[dockIndex].items[itemIndex] != item else { return }
        docks[dockIndex].items[itemIndex] = item
    }

    func removeItem(_ itemID: UUID, from dockID: UUID) {
        guard let index = docks.firstIndex(where: { $0.id == dockID }) else { return }
        docks[index].items.removeAll { $0.id == itemID }
    }
}
