import AppKit

/// An `NSMenuItem` that runs a closure, so context menus can be built inline
/// next to the code they trigger instead of through a web of selectors.
final class ClosureMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, symbol: String? = nil, enabled: Bool = true, state: NSControl.StateValue = .off,
                     key: String = "", handler: (() -> Void)?) {
        self.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: key)
        self.handler = handler
        self.target = self
        self.isEnabled = enabled && handler != nil
        self.state = state
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @objc private func fire() { handler?() }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, symbol: String? = nil, enabled: Bool = true, state: NSControl.StateValue = .off,
             key: String = "", _ handler: (() -> Void)?) -> NSMenuItem {
        let item = ClosureMenuItem(title, symbol: symbol, enabled: enabled, state: state, key: key, handler: handler)
        addItem(item)
        return item
    }

    func addHeader(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
    }
}
