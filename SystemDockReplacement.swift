import Foundation
import Combine

/// Makes the *real* Dock disappear so one of Dawck's own docks — fully
/// themeable, unlike the system one — can stand in its place.
///
/// This is not reskinning the system Dock. Nothing can: `Dock.app` is a
/// protected system process with a private, unthemeable rendering path and no
/// public API that reaches into it. What every "Dock replacement" utility
/// actually does, this one included, is the same two-step trick: make the
/// real Dock stop showing itself, and put a look-alike in the same place that
/// *is* yours to theme. Dawck already has the look-alike — a dock in
/// `.liveDock` content mode mirrors the real Dock's own apps — so replacement
/// is really just "hide the real one and point you at that."
///
/// ## How hiding works
///
/// There's no public "hide the Dock" call either. The mechanism is the same
/// one long-standing hide-the-dock tutorials use: turn autohide on, and set
/// its reveal delay absurdly high. The Dock still auto-hides normally — it
/// just never finishes the hover-to-reveal countdown in any practical amount
/// of time, so it reads as gone rather than as hidden-but-summonable. Setting
/// `autohide` off again is the exact undo, from System Settings alone, with
/// no dependency on Dawck still being installed — that fallback matters
/// enough to be worth stating up front, since this is a standing change to
/// the real Dock that persists whether or not Dawck is running.
enum SystemDockReplacement {
    /// Effectively "never" without being an actual infinity that some code
    /// path downstream might choke on.
    private static let effectivelyForeverDelay: Double = 100_000

    private static let savedStateKey = "systemDockReplacement.savedAutohideState"

    /// Whether Dawck itself is the one currently hiding the Dock — distinct
    /// from the user having their *own*, ordinary autohide turned on, which
    /// this feature must not stomp or claim credit for.
    static var isActive: Bool {
        UserDefaults.standard.data(forKey: savedStateKey) != nil
    }

    /// Hides the real Dock, remembering its exact prior autohide settings so
    /// `restore()` can put them back precisely rather than merely turning
    /// autohide off — a user who already had autohide on with a custom delay
    /// gets that back, not a reset to the app's defaults.
    static func hide(completion: @escaping () -> Void = {}) {
        DispatchQueue.global(qos: .userInitiated).async {
            let previous = DockDefaultsManager.readAutohideState()
            if let data = try? JSONEncoder().encode(previous) {
                UserDefaults.standard.set(data, forKey: savedStateKey)
            }
            DockDefaultsManager.writeAutohideState(
                DockDefaultsManager.AutohideState(
                    autohide: true,
                    delay: effectivelyForeverDelay,
                    timeModifier: previous.timeModifier
                )
            )
            DispatchQueue.main.async { completion() }
        }
    }

    /// Restores whatever autohide state was in effect right before `hide()`.
    /// Safe to call even if nothing is stored — falls back to plain "autohide
    /// off" rather than doing nothing, so this is never a dead button.
    static func restore(completion: @escaping () -> Void = {}) {
        let previous: DockDefaultsManager.AutohideState
        if let data = UserDefaults.standard.data(forKey: savedStateKey),
           let decoded = try? JSONDecoder().decode(DockDefaultsManager.AutohideState.self, from: data) {
            previous = decoded
        } else {
            previous = DockDefaultsManager.AutohideState(autohide: false, delay: 0.5, timeModifier: 0.5)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            DockDefaultsManager.writeAutohideState(previous)
            DispatchQueue.main.async {
                UserDefaults.standard.removeObject(forKey: savedStateKey)
                completion()
            }
        }
    }

    /// Builds (or reuses) the dock meant to stand in for the real one: a
    /// live mirror, centred at the bottom edge, sized and spaced the way the
    /// system Dock normally is — a reasonable starting point, not a lock-in,
    /// since it's an ordinary Dawck dock the user can re-theme or reshape
    /// from here exactly like any other.
    static func makeOrUpdateStandInDock(in store: SecondaryDockStore) -> SecondaryDock {
        if let existing = store.docks.first(where: { $0.contentMode == .liveDock && $0.edge == .bottom }) {
            var updated = existing
            updated.isEnabled = true
            store.update(updated)
            return updated
        }

        var dock = SecondaryDock(
            name: "System Dock Replacement",
            edge: .bottom,
            alignment: 0.5,
            edgeMargin: 6,
            contentMode: .liveDock,
            tileSize: 54,
            magnificationEnabled: true,
            magnifiedTileSize: 78,
            showsRunningIndicators: true,
            layoutMode: .floating
        )
        dock.id = UUID()
        store.docks.append(dock)
        return dock
    }
}
