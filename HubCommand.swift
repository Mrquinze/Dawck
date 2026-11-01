import Foundation
import Combine

/// The menu bar consolidation channel with Yair's Apps, the menu bar hub.
///
/// Distributed notifications rather than a `dockcraft://` URL, deliberately. A
/// URL open goes through LaunchServices, which is a *launch* primitive: aimed
/// at Dawck while it is still finishing its own launch, it can cause the
/// half-started instance to be replaced. Consolidation never wants to launch
/// anything, so it has no business going through the launcher.
///
/// Dawck asks for the current state rather than waiting to be told, so
/// there's no window in which it has launched but the hub hasn't noticed yet.
///
/// The state rides in the notification *name*; `userInfo` on distributed
/// notifications doesn't cross a sandbox boundary reliably, and some apps in
/// this family are sandboxed.
enum HubMenuBar {
    static let hide = Notification.Name("com.matanlevi.YairsApps.menuBar.hide")
    static let show = Notification.Name("com.matanlevi.YairsApps.menuBar.show")
    static let query = Notification.Name("com.matanlevi.YairsApps.menuBar.query")

    /// Starts listening, then asks the hub what the current state is. If the hub
    /// isn't running nothing answers, and the icon simply stays visible.
    static func start(_ apply: @escaping (Bool) -> Void) {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: hide, object: nil, queue: .main) { _ in apply(false) }
        center.addObserver(forName: show, object: nil, queue: .main) { _ in apply(true) }
        center.postNotificationName(query, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

/// The hub's menu bar override, kept apart from the persisted
/// `showMenuBarItem` preference so it can never overwrite the user's choice.
///
/// In-memory on purpose: a relaunch clears it, and Dawck asks the hub for
/// the current state as soon as it's up again.
final class HubPresentation: ObservableObject {
    static let shared = HubPresentation()
    @Published var suppressesMenuBarItem = false
    private init() {}
}
