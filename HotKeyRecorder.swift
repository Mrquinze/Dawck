import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A button that records a global shortcut: click it, press a combination
/// (with at least one of ⌃ ⌥ ⌘), done. Escape cancels, Delete clears.
struct HotKeyRecorder: View {
    @Binding var spec: HotKeySpec?
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(label).frame(minWidth: 110)
            }
            .glassButtonStyle(prominent: isRecording)
            if spec != nil, !isRecording {
                Button { spec = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove the shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private var label: String {
        if isRecording { return rejected ? "Add ⌃ ⌥ or ⌘…" : "Press a shortcut…" }
        return spec.map(HotKeyCenter.describe) ?? "Record Shortcut"
    }

    private func start() {
        isRecording = true
        rejected = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) { spec = nil; stop(); return nil }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            // A bare letter would make a global shortcut swallow normal typing.
            guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { rejected = true; return nil }
            spec = HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
