import AppKit
import Carbon.HIToolbox

/// Global keyboard shortcuts for docks, through the Carbon hot-key API.
///
/// `RegisterEventHotKey` is the one global-shortcut mechanism that needs neither
/// Accessibility nor Input Monitoring permission: the system matches the key
/// combination itself and tells the app only that it was pressed, without ever
/// showing the app what was typed.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4457434B  // 'DWCK'

    private init() {}

    /// Returns an identifier to unregister with, or `nil` if the system refused
    /// the combination (another app already owns it).
    func register(_ spec: HotKeySpec, handler: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return nil }
        references[id] = reference
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        handlers[id] = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == noErr, hotKeyID.signature == HotKeyCenter.signature {
                DispatchQueue.main.async { HotKeyCenter.shared.handlers[hotKeyID.id]?() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    /// A short human-readable form such as "⌃⌥D", for settings.
    static func describe(_ spec: HotKeySpec) -> String {
        var text = ""
        if spec.modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if spec.modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if spec.modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if spec.modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName(spec.keyCode)
    }

    private static func keyName(_ code: UInt32) -> String {
        let special: [UInt32: String] = [UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
                                         UInt32(kVK_Escape): "⎋", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
                                         UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓", UInt32(kVK_Delete): "⌫"]
        if let name = special[code] { return name }
        if code >= UInt32(kVK_F1), let n = [UInt32(kVK_F1): 1, UInt32(kVK_F2): 2, UInt32(kVK_F3): 3, UInt32(kVK_F4): 4,
                                            UInt32(kVK_F5): 5, UInt32(kVK_F6): 6, UInt32(kVK_F7): 7, UInt32(kVK_F8): 8][code] {
            return "F\(n)"
        }
        // Translate through the current layout so the label matches the keycap.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "Key \(code)" }
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        return status == noErr && length > 0 ? String(utf16CodeUnits: chars, count: length).uppercased() : "Key \(code)"
    }
}
