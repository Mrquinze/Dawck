import Foundation
import CoreAudio
import AppKit
import Combine

/// Lists audio output devices and switches the system default — DockDoor's
/// audio device switcher. CoreAudio's HAL is public and needs no permission;
/// only microphone *input* would prompt, and this never touches input.
final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()

    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
        let isDefault: Bool
    }

    @Published private(set) var outputs: [Device] = []

    /// Called when the default output changes, so widgets can redraw.
    var onChange: (() -> Void)?

    private var listener: AudioObjectPropertyListenerBlock?
    private var subscribers = 0

    private init() {}

    func start() {
        subscribers += 1
        refresh()
        guard listener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // A listener rather than a poll: device changes are events, and
        // plugging in headphones should be reflected at once.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
            self?.onChange?()
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        listener = block
    }

    func stop() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0, let block = listener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        listener = nil
    }

    var currentOutputName: String {
        outputs.first(where: \.isDefault)?.name ?? "Output"
    }

    func refresh() {
        let defaultID = Self.defaultOutputDeviceID()
        outputs = Self.allDeviceIDs()
            .filter { Self.hasOutputStreams($0) }
            .compactMap { id in
                guard let name = Self.name(of: id) else { return nil }
                return Device(id: id, name: name, isDefault: id == defaultID)
            }
    }

    func select(_ device: Device) {
        var deviceID = device.id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &deviceID)
        refresh()
    }

    // MARK: - CoreAudio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    /// A device with no output streams is an input-only device (a microphone).
    /// Listing those in an output switcher would offer selections that silently
    /// do nothing.
    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // `Unmanaged<CFString>?` rather than a bare `CFString`. CoreAudio hands
        // back a +1 retained string through a raw pointer, and pointing ARC at
        // a managed `CFString` variable makes it believe it already owns that
        // reference — so it releases one it never retained. `Unmanaged` states
        // the ownership transfer explicitly, and `takeRetainedValue` consumes
        // the +1 exactly once.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        guard let string = name?.takeRetainedValue() as String? else { return nil }
        return string.isEmpty ? nil : string
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }
}
