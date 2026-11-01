import Foundation
import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import CoreAudio
import AudioToolbox
import Network
import Carbon.HIToolbox
import Darwin

/// The one place widget data comes from.
///
/// The widgets it replaces each ran their own timers, from a one-second metrics
/// poll shared by everything to a 0.1 s stopwatch tick and a three-second
/// AppleScript round trip for "now playing" — all of it republishing into
/// SwiftUI views that re-laid-out whole docks. Here every source is started only
/// while a visible widget needs it, prefers a system notification to a timer
/// (battery, volume, keyboard layout, thermal state, the Music and Spotify
/// players, network changes), and aligns the timers that remain to the boundary
/// they display, so a minute clock wakes the process once a minute.
///
/// Owners subscribe with the tiles they show; the hub tells them *when* one of
/// those tiles has something new, and they ask for a `WidgetSnapshot`. Snapshots
/// are plain values, so a tile re-renders only when its snapshot actually
/// differs from the last one.
final class WidgetHub {
    static let shared = WidgetHub()

    // MARK: Subscriptions

    private struct Subscription {
        var kinds: Set<DockWidgetKind>
        var needsSeconds: Bool
        var graphs: Int
        var wantsPublicIP: Bool
        var weatherKeys: Set<String>
        var handler: () -> Void
    }

    private var subscriptions: [ObjectIdentifier: Subscription] = [:]
    private var counts: [DockWidgetKind: Int] = [:]
    private var secondsRequests = 0
    private var pendingKinds: Set<DockWidgetKind> = []
    private var flushScheduled = false
    private var suspended = false

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setSuspended(true) }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setSuspended(false) }
        }
        for name in [NSNotification.Name.NSSystemClockDidChange, NSNotification.Name.NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.touch([.clock, .date, .analogClock, .worldClock, .calendar])
                self?.rescheduleClock()
            }
        }
    }

    /// Declares which tiles `owner` is showing. Calling it again replaces the
    /// previous declaration; an empty list releases everything.
    func subscribe(_ owner: AnyObject, items: [DockItem], handler: @escaping () -> Void) {
        let key = ObjectIdentifier(owner)
        let widgets = items.filter { $0.kind == .widget }
        let kinds = Set(widgets.map(\.widget))
        let seconds = widgets.contains { $0.widgetOptions.showsSeconds && [.clock, .analogClock, .worldClock].contains($0.widget) }
        let graphs = widgets.filter { $0.widget.supportsGraph && $0.widgetOptions.style == .graph }.count
        let publicIP = widgets.contains { $0.widget == .ip && $0.widgetOptions.ipMode != .local }
        let weatherKeys = Set(widgets.filter { $0.widget == .weather }.compactMap { Self.weatherKey($0.widgetOptions) })
        if let old = subscriptions[key] { release(old) }
        guard !kinds.isEmpty else { subscriptions[key] = nil; reconcile(); return }
        let subscription = Subscription(kinds: kinds, needsSeconds: seconds, graphs: graphs, wantsPublicIP: publicIP,
                                        weatherKeys: weatherKeys, handler: handler)
        subscriptions[key] = subscription
        for kind in kinds { counts[kind, default: 0] += 1 }
        reconcile()
    }

    func unsubscribe(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        guard let old = subscriptions.removeValue(forKey: key) else { return }
        release(old)
        reconcile()
    }

    private func release(_ subscription: Subscription) {
        for kind in subscription.kinds {
            let remaining = (counts[kind] ?? 1) - 1
            counts[kind] = remaining > 0 ? remaining : nil
        }
    }

    private func wants(_ kinds: DockWidgetKind...) -> Bool { kinds.contains { counts[$0] != nil } }

    /// Marks kinds as changed; subscribers are told once, on the next run-loop turn.
    private func touch(_ kinds: Set<DockWidgetKind>) {
        pendingKinds.formUnion(kinds)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let changed = self.pendingKinds
            self.pendingKinds = []
            self.flushScheduled = false
            for subscription in self.subscriptions.values where !subscription.kinds.isDisjoint(with: changed) {
                subscription.handler()
            }
        }
    }

    private func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        reconcile()
        if !value {
            // Everything shown is stale after a sleep.
            touch(Set(counts.keys))
        }
    }

    // MARK: State

    private var cpu = 0.0, gpu: Double?, memory = 0.0, disk = 0.0
    private var cpuHistory: [Double] = [], memoryHistory: [Double] = [], gpuHistory: [Double] = [], networkHistory: [Double] = []
    private var downRate = 0.0, upRate = 0.0
    private var networkPeak = 1_000_000.0
    private var battery = BatteryReading()
    private var volume = 0.5, muted = false
    private var peripherals: [(symbol: String, name: String, percent: Int)] = []
    private var keyboard = (abbreviation: "–", name: "")
    private var playing = NowPlayingState()
    private var localIP = "", publicIP = ""
    private var weather: [String: WeatherReading] = [:]
    private var stopwatch = StopwatchModel()
    private var countdown = CountdownModel()
    private var caffeineAssertion: IOPMAssertionID = 0
    private(set) var isCaffeinated = false

    private struct BatteryReading {
        var hasBattery = false, level = 1.0, charging = false, onAC = true
        var minutesRemaining: Int?
    }
    private struct NowPlayingState {
        var title = "", artist = "", isPlaying = false, app: String?
    }
    private struct WeatherReading { var temperature: Double, code: Int, isDay: Bool }
    private struct StopwatchModel {
        var startedAt: Date?, accumulated: TimeInterval = 0
        var elapsed: TimeInterval { accumulated + (startedAt.map { Date().timeIntervalSince($0) } ?? 0) }
    }
    private struct CountdownModel {
        var total: TimeInterval = 0, endsAt: Date?, pausedRemaining: TimeInterval?
        var remaining: TimeInterval { endsAt.map { max(0, $0.timeIntervalSinceNow) } ?? pausedRemaining ?? total }
        var isRunning: Bool { endsAt != nil }
    }

    // MARK: Source lifecycle

    private let sampleQueue = DispatchQueue(label: "com.matanlevi.Dawck.widgets", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var pollTick = 0
    private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var previousNetwork: (rx: UInt64, tx: UInt64, at: Date)?
    private var clockTimer: DispatchSourceTimer?
    private var peripheralsTimer: DispatchSourceTimer?
    private var weatherTimer: DispatchSourceTimer?
    private var batterySource: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?
    private var keyboardObserver: NSObjectProtocol?
    private var playerObservers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var audioOutputActive = false

    private func reconcile() {
        graphSubscribers = subscriptions.values.reduce(0) { $0 + $1.graphs }
        secondsRequests = subscriptions.values.filter(\.needsSeconds).count
        let publicWanted = subscriptions.values.contains { $0.wantsPublicIP }
        if publicWanted != wantsPublicIP { wantsPublicIP = publicWanted; refreshPublicIPIfNeeded() }
        let locations = subscriptions.values.reduce(into: Set<String>()) { $0.formUnion($1.weatherKeys) }
        if locations != weatherLocations { weatherLocations = locations; fetchWeather() }

        // Polled numbers
        let needsPoll = !suspended && wants(.cpu, .memory, .gpu, .network, .disk)
        if needsPoll, pollTimer == nil { startPolling() } else if !needsPoll, pollTimer != nil { stopPolling() }

        // Time
        let timeKinds = wants(.clock, .date, .analogClock, .worldClock, .calendar)
        let ticking = (wants(.timer) && stopwatch.startedAt != nil) || (wants(.countdown) && countdown.isRunning)
        if !suspended && (timeKinds || ticking) { rescheduleClock() } else { clockTimer?.cancel(); clockTimer = nil }

        // Event sources
        setBattery(!suspended && wants(.battery))
        setThermal(wants(.thermal))
        setKeyboard(wants(.keyboardLayout))
        setPlayers(wants(.nowPlaying))
        setVolume(wants(.volume))
        setAudioOutput(wants(.audioOutput))
        setNetworkPath(wants(.ip))
        setPeripherals(!suspended && wants(.peripherals))
        setWeather(!suspended && wants(.weather))
    }

    // MARK: Polling (cpu, memory, gpu, network, disk)

    private func startPolling() {
        pollTick = 0
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now() + 0.2, repeating: 2.0, leeway: .milliseconds(400))
        timer.setEventHandler { [weak self] in self?.pollOnQueue() }
        timer.resume()
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
        sampleQueue.async { [weak self] in self?.previousTicks = nil; self?.previousNetwork = nil }
    }

    /// Runs on the sample queue. Only the readings somebody is showing are taken.
    private func pollOnQueue() {
        let tick = pollTick
        pollTick &+= 1
        var cpuValue: Double?, memValue: Double?, gpuValue: Double??, diskValue: Double?
        var net: (down: Double, up: Double)?
        let (wantsCPU, wantsMemory, wantsGPU, wantsNet, wantsDisk) = DispatchQueue.main.sync {
            (wants(.cpu), wants(.memory), wants(.gpu), wants(.network), wants(.disk))
        }
        if wantsCPU { cpuValue = sampleCPU() }
        if wantsMemory, tick % 2 == 0 { memValue = Self.memoryFraction() }
        if wantsGPU { gpuValue = .some(Self.gpuUtilization()) }
        if wantsNet { net = sampleNetwork() }
        if wantsDisk, tick % 30 == 0 { diskValue = Self.diskUsedFraction() }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var changed: Set<DockWidgetKind> = []
            if let cpuValue, Self.differs(self.cpu, cpuValue) { self.cpu = cpuValue; changed.insert(.cpu) }
            if let cpuValue { Self.push(&self.cpuHistory, cpuValue) }
            if let memValue, Self.differs(self.memory, memValue) { self.memory = memValue; changed.insert(.memory) }
            if let memValue { Self.push(&self.memoryHistory, memValue) }
            if let reading = gpuValue {
                let previous = self.gpu
                self.gpu = reading
                if let reading { Self.push(&self.gpuHistory, reading) }
                if (previous == nil) != (reading == nil) || Self.differs(previous ?? 0, reading ?? 0) { changed.insert(.gpu) }
            }
            if let net {
                self.networkPeak = max(1_000_000, self.networkPeak * 0.97, net.down + net.up)
                Self.push(&self.networkHistory, min((net.down + net.up) / self.networkPeak, 1))
                if Self.rateText(net.down) != Self.rateText(self.downRate) || Self.rateText(net.up) != Self.rateText(self.upRate) {
                    changed.insert(.network)
                } else if self.graphSubscribers > 0 { changed.insert(.network) }
                self.downRate = net.down
                self.upRate = net.up
            }
            if let diskValue, Self.differs(self.disk, diskValue) { self.disk = diskValue; changed.insert(.disk) }
            if self.graphsShown { changed.formUnion([.cpu, .memory, .gpu].filter { self.counts[$0] != nil }) }
            if !changed.isEmpty { self.touch(changed) }
        }
    }

    /// Whether any subscriber draws a graph — then every sample matters, not
    /// only the ones that change the number.
    private var graphsShown: Bool { graphSubscribers > 0 }
    private var graphSubscribers = 0

    private static func differs(_ a: Double, _ b: Double) -> Bool { Int((a * 100).rounded()) != Int((b * 100).rounded()) }
    private static func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > 30 { history.removeFirst(history.count - 30) }
    }

    private func sampleCPU() -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let current = (user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { previousTicks = current }
        guard let previous = previousTicks else { return nil }
        let user = Double(current.user &- previous.user), system = Double(current.system &- previous.system)
        let idle = Double(current.idle &- previous.idle), nice = Double(current.nice &- previous.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return min(1, max(0, (user + system + nice) / total))
    }

    private static func memoryFraction() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Double(vm_kernel_page_size)
        let used = Double(stats.active_count) * page + Double(stats.wire_count) * page + Double(stats.compressor_page_count) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? min(1, max(0, used / total)) : nil
    }

    private static func diskUsedFraction() -> Double? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let free = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
        return min(1, max(0, 1 - free / Double(total)))
    }

    private static func forEachService(_ name: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            body(entry)
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }

    private static func gpuUtilization() -> Double? {
        var best: Double?
        forEachService("IOAccelerator") { entry in
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            best = max(best ?? 0, value)
        }
        return best.map { min(max($0 / 100, 0), 1) }
    }

    private static func networkBytes() -> (rx: UInt64, tx: UInt64) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (0, 0) }
        defer { freeifaddrs(list) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            if let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0, let data = current.pointee.ifa_data {
                let counters = data.assumingMemoryBound(to: if_data.self).pointee
                rx += UInt64(counters.ifi_ibytes)
                tx += UInt64(counters.ifi_obytes)
            }
            cursor = current.pointee.ifa_next
        }
        return (rx, tx)
    }

    private func sampleNetwork() -> (down: Double, up: Double)? {
        let now = Date()
        let bytes = Self.networkBytes()
        defer { previousNetwork = (bytes.rx, bytes.tx, now) }
        guard let previous = previousNetwork else { return nil }
        let seconds = max(now.timeIntervalSince(previous.at), 0.1)
        // A counter that went backwards wrapped or an interface vanished; one
        // sample of zero is better than a spike.
        let down = bytes.rx >= previous.rx ? Double(bytes.rx - previous.rx) / seconds : 0
        let up = bytes.tx >= previous.tx ? Double(bytes.tx - previous.tx) / seconds : 0
        return (down, up)
    }

    private static func rateText(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1_000: return "0 KB/s"
        case ..<1_000_000: return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        case ..<10_000_000: return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        case ..<1_000_000_000: return String(format: "%.0f MB/s", bytesPerSecond / 1_000_000)
        default: return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
        }
    }

    // MARK: Clock

    private func rescheduleClock() {
        clockTimer?.cancel()
        clockTimer = nil
        guard !suspended else { return }
        let ticking = (wants(.timer) && stopwatch.startedAt != nil) || (wants(.countdown) && countdown.isRunning)
        let interval: TimeInterval = (secondsRequests > 0 || ticking) ? 1 : 60
        let now = Date().timeIntervalSinceReferenceDate
        let next = (now / interval).rounded(.down) * interval + interval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + (next - now), repeating: interval, leeway: .milliseconds(interval > 1 ? 250 : 80))
        timer.setEventHandler { [weak self] in self?.clockFired() }
        timer.resume()
        clockTimer = timer
    }

    private func clockFired() {
        var changed: Set<DockWidgetKind> = [.clock, .date, .analogClock, .worldClock, .calendar]
        if stopwatch.startedAt != nil { changed.insert(.timer) }
        if countdown.isRunning {
            changed.insert(.countdown)
            if countdown.remaining <= 0 {
                countdown.endsAt = nil
                countdown.pausedRemaining = nil
                NSSound.beep()
                reconcile()
            }
        }
        touch(changed)
    }

    // MARK: Battery

    private func setBattery(_ on: Bool) {
        if on, batterySource == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let callback: IOPowerSourceCallbackType = { raw in
                guard let raw else { return }
                let hub = Unmanaged<WidgetHub>.fromOpaque(raw).takeUnretainedValue()
                DispatchQueue.main.async { hub.readBattery() }
            }
            if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                batterySource = source
            }
            readBattery()
        } else if !on, let source = batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            batterySource = nil
        }
    }

    private func readBattery() {
        var reading = BatteryReading()
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                reading.hasBattery = true
                reading.level = min(1, Double(capacity) / Double(maximum))
                reading.charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
                reading.onAC = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes > 0, !reading.onAC { reading.minutesRemaining = minutes }
                if let minutes = description[kIOPSTimeToFullChargeKey] as? Int, minutes > 0, reading.charging { reading.minutesRemaining = minutes }
                break
            }
        }
        let old = battery
        battery = reading
        if old.hasBattery != reading.hasBattery || Self.differs(old.level, reading.level)
            || old.charging != reading.charging || old.onAC != reading.onAC || old.minutesRemaining != reading.minutesRemaining {
            touch([.battery])
        }
    }

    // MARK: Thermal

    private func setThermal(_ on: Bool) {
        if on, thermalObserver == nil {
            thermalObserver = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.touch([.thermal]) }
        } else if !on, let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalObserver = nil
        }
    }

    // MARK: Keyboard layout

    private func setKeyboard(_ on: Bool) {
        if on, keyboardObserver == nil {
            readKeyboard()
            keyboardObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
            ) { [weak self] _ in
                self?.readKeyboard()
                self?.touch([.keyboardLayout])
            }
        } else if !on, let observer = keyboardObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            keyboardObserver = nil
        }
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> Any? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }

    private func readKeyboard() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let name = Self.property(source, kTISPropertyLocalizedName) as? String ?? ""
        let languages = Self.property(source, kTISPropertyInputSourceLanguages) as? [String]
        let abbreviation = (languages?.first).map { String($0.prefix(2)).uppercased() } ?? String(name.prefix(2)).uppercased()
        keyboard = (abbreviation, name)
    }

    func cycleKeyboardLayout() {
        let filter = [kTISPropertyInputSourceIsEnabled as String: true,
                      kTISPropertyInputSourceIsSelectCapable as String: true,
                      kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource], list.count > 1,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        let currentID = Self.property(current, kTISPropertyInputSourceID) as? String
        let index = list.firstIndex { (Self.property($0, kTISPropertyInputSourceID) as? String) == currentID } ?? -1
        TISSelectInputSource(list[(index + 1) % list.count])
    }

    // MARK: Now playing

    private func setPlayers(_ on: Bool) {
        if on, playerObservers.isEmpty {
            let center = DistributedNotificationCenter.default()
            for (name, app) in [("com.apple.Music.playerInfo", "Music"), ("com.spotify.client.PlaybackStateChanged", "Spotify")] {
                playerObservers.append(center.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] note in
                    self?.playerChanged(note.userInfo, app: app)
                })
            }
        } else if !on, !playerObservers.isEmpty {
            playerObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
            playerObservers = []
        }
    }

    /// Player apps broadcast their state; no scripting, and no Automation prompt,
    /// is needed to read it. The strings come from another process, so they are
    /// length-limited and stripped of control characters before they are shown.
    private func playerChanged(_ info: [AnyHashable: Any]?, app: String) {
        guard let info else { return }
        func clean(_ value: Any?) -> String {
            let text = (value as? String) ?? ""
            return String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120).map(Character.init))
        }
        let state = clean(info["Player State"]).lowercased()
        var next = playing
        next.app = app
        if state == "stopped" {
            next.title = ""; next.artist = ""; next.isPlaying = false
        } else {
            next.title = clean(info["Name"])
            next.artist = clean(info["Artist"])
            next.isPlaying = state == "playing"
        }
        guard next.title != playing.title || next.artist != playing.artist || next.isPlaying != playing.isPlaying else { return }
        playing = next
        touch([.nowPlaying])
    }

    /// Transport goes to the app that last announced itself. This is the one
    /// place scripting is used, and only when the user clicks.
    func nowPlayingCommand(_ command: String) {
        // Only these two apps and these three commands are ever scripted.
        guard let app = playing.app, ["Music", "Spotify"].contains(app),
              ["playpause", "next track", "previous track"].contains(command) else { return }
        NSAppleScript(source: "tell application \"\(app)\" to \(command)")?.executeAndReturnError(nil)
    }
    func playPause() { nowPlayingCommand("playpause") }

    // MARK: Volume

    private static var outputVolumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?
    private var volumeBlocks: [(device: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    private func setVolume(_ on: Bool) {
        if on {
            if defaultDeviceBlock == nil {
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.attachVolumeListeners()
                    self?.touch([.volume, .audioOutput])
                }
                var address = Self.defaultOutputAddress
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
                defaultDeviceBlock = block
                attachVolumeListeners()
            }
        } else if let block = defaultDeviceBlock {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            defaultDeviceBlock = nil
            detachVolumeListeners()
        }
    }

    private func attachVolumeListeners() {
        detachVolumeListeners()
        let device = Self.defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return }
        for var address in [Self.outputVolumeAddress, Self.muteAddress] {
            guard AudioObjectHasProperty(device, &address) else { continue }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.readVolume()
                self?.touch([.volume])
            }
            AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
            volumeBlocks.append((device, address, block))
        }
        readVolume()
    }

    private func detachVolumeListeners() {
        for entry in volumeBlocks {
            var address = entry.address
            AudioObjectRemovePropertyListenerBlock(entry.device, &address, .main, entry.block)
        }
        volumeBlocks = []
    }

    private func readVolume() {
        let device = Self.defaultOutputDevice()
        var address = Self.outputVolumeAddress
        var value = Float32(0.5)
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { volume = Double(value) }
        var muteAddress = Self.muteAddress
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress),
           AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &mute) == noErr { muted = mute != 0 }
    }

    func adjustVolume(by delta: Double) {
        let device = Self.defaultOutputDevice()
        var address = Self.outputVolumeAddress
        var value = Float32(min(max(volume + delta, 0), 1))
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        readVolume()
        touch([.volume])
    }

    func toggleMute() {
        let device = Self.defaultOutputDevice()
        var address = Self.muteAddress
        var value = UInt32(muted ? 0 : 1)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        readVolume()
        touch([.volume])
    }

    // MARK: Audio output name

    private func setAudioOutput(_ on: Bool) {
        guard on != audioOutputActive else { return }
        audioOutputActive = on
        if on {
            AudioDevices.shared.start()
            AudioDevices.shared.onChange = { [weak self] in self?.touch([.audioOutput]) }
        } else {
            AudioDevices.shared.onChange = nil
            AudioDevices.shared.stop()
        }
    }

    // MARK: IP

    private func setNetworkPath(_ on: Bool) {
        if on, pathMonitor == nil {
            refreshLocalIP()
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshLocalIP()
                    self?.publicIPFetchedAt = nil
                    self?.refreshPublicIPIfNeeded()
                }
            }
            monitor.start(queue: sampleQueue)
            pathMonitor = monitor
            refreshPublicIPIfNeeded()
        } else if !on, let monitor = pathMonitor {
            monitor.cancel()
            pathMonitor = nil
        }
    }

    private var publicIPFetchedAt: Date?
    /// Whether any visible IP tile shows the public address — so the hub never
    /// makes a request nobody asked for.
    private var wantsPublicIP = false

    private func refreshLocalIP() {
        let address = Self.localIPv4() ?? ""
        if address != localIP { localIP = address; touch([.ip]) }
    }

    private static func localIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((String(cString: current.pointee.ifa_name), String(cString: host)))
        }
        return (found.first { $0.name == "en0" } ?? found.first { $0.name.hasPrefix("en") } ?? found.first)?.address
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private func refreshPublicIPIfNeeded() {
        guard wantsPublicIP, pathMonitor != nil else { return }
        if let at = publicIPFetchedAt, Date().timeIntervalSince(at) < 600 { return }
        publicIPFetchedAt = Date()
        guard let url = URL(string: "https://api.ipify.org") else { return }
        session.dataTask(with: url) { [weak self] data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200, data.count < 64,
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            // The reply is shown and can be copied; only a literal IP address is accepted.
            var v4 = in_addr(), v6 = in6_addr()
            guard inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1 else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.publicIP != text { self.publicIP = text; self.touch([.ip]) }
            }
        }.resume()
    }

    func copyIPToPasteboard(mode: IPDisplayMode) -> String? {
        let text = mode == .publicAddress ? publicIP : localIP
        guard !text.isEmpty else { return nil }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return text
    }

    // MARK: Peripherals

    private func setPeripherals(_ on: Bool) {
        if on, peripheralsTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
            timer.schedule(deadline: .now(), repeating: 180, leeway: .seconds(30))
            timer.setEventHandler { [weak self] in
                let devices = Self.readPeripherals()
                DispatchQueue.main.async {
                    guard let self else { return }
                    let changed = devices.map { "\($0.name)\($0.percent)" } != self.peripherals.map { "\($0.name)\($0.percent)" }
                    self.peripherals = devices
                    if changed { self.touch([.peripherals]) }
                }
            }
            timer.resume()
            peripheralsTimer = timer
        } else if !on, let timer = peripheralsTimer {
            timer.cancel()
            peripheralsTimer = nil
        }
    }

    private static func readPeripherals() -> [(symbol: String, name: String, percent: Int)] {
        var devices: [(String, String, Int)] = []
        forEachService("AppleDeviceManagementHIDEventService") { entry in
            guard let percent = (IORegistryEntryCreateCFProperty(entry, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue, (0...100).contains(percent) else { return }
            let product = (IORegistryEntryCreateCFProperty(entry, "Product" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String) ?? "Device"
            let lower = product.lowercased()
            let symbol = lower.contains("keyboard") ? "keyboard" : lower.contains("mouse") ? "computermouse"
                : lower.contains("trackpad") ? "rectangle.and.hand.point.up.left" : "dot.radiowaves.left.and.right"
            if !devices.contains(where: { $0.1 == product }) { devices.append((symbol, String(product.prefix(40)), percent)) }
        }
        return devices.sorted { $0.1 < $1.1 }.map { (symbol: $0.0, name: $0.1, percent: $0.2) }
    }

    // MARK: Weather

    private var weatherLocations: Set<String> = []

    private static func weatherKey(_ options: WidgetOptions) -> String? {
        guard let lat = options.latitude, let lon = options.longitude else { return nil }
        return String(format: "%.2f,%.2f", lat, lon)
    }

    private func setWeather(_ on: Bool) {
        if on, weatherTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1800, repeating: 1800, leeway: .seconds(120))
            timer.setEventHandler { [weak self] in self?.fetchWeather() }
            timer.resume()
            weatherTimer = timer
            fetchWeather()
        } else if !on, let timer = weatherTimer {
            timer.cancel()
            weatherTimer = nil
        }
    }

    private func fetchWeather() {
        guard weatherTimer != nil else { return }
        for key in weatherLocations {
            let parts = key.split(separator: ",")
            guard parts.count == 2,
                  let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(parts[0])&longitude=\(parts[1])&current=temperature_2m,weather_code,is_day")
            else { continue }
            session.dataTask(with: url) { [weak self] data, response, _ in
                guard let data, data.count < 20_000, (response as? HTTPURLResponse)?.statusCode == 200,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let current = root["current"] as? [String: Any],
                      let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue, temperature.isFinite,
                      let code = (current["weather_code"] as? NSNumber)?.intValue else { return }
                let isDay = ((current["is_day"] as? NSNumber)?.intValue ?? 1) == 1
                DispatchQueue.main.async {
                    self?.weather[key] = WeatherReading(temperature: temperature, code: code, isDay: isDay)
                    self?.touch([.weather])
                }
            }.resume()
        }
    }

    /// City search for the weather widget's settings, via Open-Meteo's geocoder.
    static func geocode(_ city: String) async -> (name: String, latitude: Double, longitude: Double)? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [URLQueryItem(name: "name", value: String(city.prefix(80))), URLQueryItem(name: "count", value: "1")]
        guard let url = components?.url else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        guard let (data, _) = try? await URLSession(configuration: configuration).data(from: url), data.count < 50_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["results"] as? [[String: Any]])?.first,
              let latitude = (first["latitude"] as? NSNumber)?.doubleValue, abs(latitude) <= 90,
              let longitude = (first["longitude"] as? NSNumber)?.doubleValue, abs(longitude) <= 180 else { return nil }
        return ((first["name"] as? String).map { String($0.prefix(60)) } ?? city, latitude, longitude)
    }

    // MARK: Controls

    func toggleStopwatch() {
        if let started = stopwatch.startedAt {
            stopwatch.accumulated += Date().timeIntervalSince(started)
            stopwatch.startedAt = nil
        } else {
            stopwatch.startedAt = Date()
        }
        reconcile()
        touch([.timer])
    }

    func resetStopwatch() {
        stopwatch.accumulated = 0
        if stopwatch.startedAt != nil { stopwatch.startedAt = Date() }
        reconcile()
        touch([.timer])
    }

    func toggleCountdown(minutes: Int) {
        if countdown.isRunning {
            countdown.pausedRemaining = countdown.remaining
            countdown.endsAt = nil
        } else {
            if countdown.pausedRemaining == nil || countdown.total != TimeInterval(minutes * 60) {
                countdown.total = TimeInterval(minutes * 60)
                countdown.pausedRemaining = nil
            }
            countdown.endsAt = Date().addingTimeInterval(countdown.pausedRemaining ?? countdown.total)
            countdown.pausedRemaining = nil
        }
        reconcile()
        touch([.countdown])
    }

    func resetCountdown() {
        countdown.endsAt = nil
        countdown.pausedRemaining = nil
        reconcile()
        touch([.countdown])
    }

    func toggleCaffeine() {
        if isCaffeinated {
            IOPMAssertionRelease(caffeineAssertion)
            caffeineAssertion = 0
            isCaffeinated = false
        } else {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Dawck Keep Awake" as CFString, &id)
            if result == kIOReturnSuccess { caffeineAssertion = id; isCaffeinated = true }
        }
        touch([.caffeine])
    }

    // MARK: Snapshots

    func snapshot(for item: DockItem, now: Date = Date()) -> WidgetSnapshot {
        let options = item.widgetOptions
        var snapshot = WidgetSnapshot()
        switch item.widget {
        case .clock:
            snapshot.primary = Self.timeText(now, timeZone: .current, options: options)
            snapshot.secondary = options.showsSeconds ? "" : Self.format(now, "EEE d MMM", timeZone: .current)
        case .analogClock:
            snapshot.date = options.showsSeconds ? now : Calendar.current.date(bySetting: .second, value: 0, of: now)
        case .worldClock:
            let zone = TimeZone(identifier: options.timeZoneID) ?? .current
            snapshot.primary = Self.timeText(now, timeZone: zone, options: options)
            snapshot.caption = zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
        case .date, .calendar:
            snapshot.caption = Self.format(now, "EEE", timeZone: .current)
            snapshot.primary = Self.format(now, "d", timeZone: .current)
        case .cpu:
            snapshot = gauge(cpu, caption: "CPU", history: cpuHistory)
        case .memory:
            snapshot = gauge(memory, caption: "RAM", history: memoryHistory)
        case .gpu:
            if let gpu { snapshot = gauge(gpu, caption: "GPU", history: gpuHistory) } else { snapshot.primary = "–"; snapshot.caption = "GPU" }
        case .disk:
            snapshot = gauge(disk, caption: "SSD", history: [])
            snapshot.tone = disk > 0.92 ? .critical : disk > 0.8 ? .warning : .normal
        case .battery:
            snapshot = batterySnapshot()
        case .network:
            snapshot.lines = ["↓ " + Self.rateText(downRate), "↑ " + Self.rateText(upRate)]
            snapshot.primary = Self.rateText(downRate + upRate)
            snapshot.history = networkHistory
        case .ip:
            let wantsLocal = options.ipMode != .publicAddress, wantsPublic = options.ipMode != .local
            snapshot.caption = options.ipMode == .local ? "LOCAL" : options.ipMode == .publicAddress ? "PUBLIC" : "IP"
            if wantsLocal { snapshot.lines.append(localIP.isEmpty ? "offline" : localIP) }
            if wantsPublic { snapshot.lines.append(publicIP.isEmpty ? "…" : publicIP) }
        case .peripherals:
            snapshot.lines = peripherals.prefix(3).map { "\($0.symbol)|\($0.percent)%" }
        case .thermal:
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: snapshot.primary = "Cool"; snapshot.symbol = "thermometer.low"; snapshot.tone = .good
            case .fair: snapshot.primary = "Warm"; snapshot.symbol = "thermometer.medium"; snapshot.tone = .normal
            case .serious: snapshot.primary = "Hot"; snapshot.symbol = "thermometer.high"; snapshot.tone = .warning
            case .critical: snapshot.primary = "Critical"; snapshot.symbol = "thermometer.sun.fill"; snapshot.tone = .critical
            @unknown default: snapshot.primary = "–"
            }
        case .timer:
            snapshot.primary = Self.stopwatchText(stopwatch.elapsed)
            snapshot.symbol = stopwatch.startedAt == nil ? "play.fill" : "pause.fill"
        case .countdown:
            let total = countdown.total > 0 ? countdown.total : TimeInterval(options.countdownMinutes * 60)
            let remaining = countdown.total > 0 ? countdown.remaining : total
            snapshot.primary = Self.stopwatchText(remaining)
            snapshot.fraction = total > 0 ? remaining / total : 0
            snapshot.symbol = countdown.isRunning ? "pause.fill" : "play.fill"
        case .audioOutput:
            snapshot.caption = AudioDevices.shared.currentOutputName
            snapshot.symbol = "hifispeaker.fill"
        case .nowPlaying:
            snapshot.primary = playing.title
            snapshot.secondary = playing.artist
            snapshot.symbol = playing.isPlaying ? "waveform" : "music.note"
            snapshot.tone = playing.isPlaying ? .good : .normal
        case .volume:
            snapshot.fraction = muted ? 0 : volume
            snapshot.primary = muted ? "Mute" : "\(Int((volume * 100).rounded()))%"
            snapshot.symbol = muted || volume == 0 ? "speaker.slash.fill" : volume < 0.34 ? "speaker.wave.1.fill"
                : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .keyboardLayout:
            snapshot.primary = keyboard.abbreviation
            snapshot.caption = keyboard.name
        case .caffeine:
            snapshot.symbol = isCaffeinated ? "cup.and.saucer.fill" : "cup.and.saucer"
            snapshot.caption = isCaffeinated ? "AWAKE" : "OFF"
            snapshot.tone = isCaffeinated ? .good : .normal
        case .weather:
            if let key = Self.weatherKey(options), let reading = weather[key] {
                let value = options.fahrenheit ? reading.temperature * 9 / 5 + 32 : reading.temperature
                snapshot.primary = "\(Int(value.rounded()))°"
                snapshot.symbol = Self.weatherSymbol(reading.code, isDay: reading.isDay)
                snapshot.caption = options.city
            } else {
                snapshot.symbol = options.latitude == nil ? "location.slash" : "cloud.sun"
                snapshot.primary = "–"
                snapshot.caption = options.latitude == nil ? "Set a city" : options.city
            }
        }
        return snapshot
    }

    private func gauge(_ value: Double, caption: String, history: [Double]) -> WidgetSnapshot {
        var snapshot = WidgetSnapshot()
        snapshot.primary = "\(Int((value * 100).rounded()))%"
        snapshot.caption = caption
        snapshot.fraction = value
        snapshot.history = history
        snapshot.tone = value > 0.9 ? .critical : value > 0.75 ? .warning : .normal
        return snapshot
    }

    private func batterySnapshot() -> WidgetSnapshot {
        var snapshot = WidgetSnapshot()
        guard battery.hasBattery else {
            snapshot.primary = "AC"; snapshot.symbol = "powerplug.fill"; snapshot.caption = "POWER"; snapshot.fraction = 1
            return snapshot
        }
        snapshot.primary = "\(Int((battery.level * 100).rounded()))%"
        snapshot.fraction = battery.level
        snapshot.symbol = battery.charging ? "bolt.fill" : nil
        if let minutes = battery.minutesRemaining {
            snapshot.caption = String(format: "%d:%02d", minutes / 60, minutes % 60) + (battery.charging ? " full" : " left")
        } else {
            snapshot.caption = battery.charging ? "CHARGING" : battery.onAC ? "PLUGGED IN" : "BATTERY"
        }
        snapshot.tone = battery.charging ? .good : battery.level < 0.1 ? .critical : battery.level < 0.2 ? .warning : .normal
        return snapshot
    }

    // MARK: Formatting

    private static var formatters: [String: DateFormatter] = [:]

    private static func format(_ date: Date, _ pattern: String, timeZone: TimeZone) -> String {
        let key = "\(pattern)|\(timeZone.identifier)|\(Locale.current.identifier)"
        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(pattern)
            formatters[key] = formatter
        }
        return formatter.string(from: date)
    }

    private static var systemUses24Hour: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }

    private static func timeText(_ date: Date, timeZone: TimeZone, options: WidgetOptions) -> String {
        let use24 = options.use24Hour ?? systemUses24Hour
        let pattern = (use24 ? "HH:mm" : "h:mm") + (options.showsSeconds ? ":ss" : "")
        let key = "t|\(pattern)|\(timeZone.identifier)"
        let formatter: DateFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            formatters[key] = formatter
        }
        return formatter.string(from: date)
    }

    private static func stopwatchText(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func weatherSymbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 80...82: return "cloud.heavy.rain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}
