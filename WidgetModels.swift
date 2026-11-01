import Foundation

/// The live readouts a widget tile can show.
///
/// Raw values of the original nine are unchanged, so docks saved by earlier
/// builds load as they were.
enum DockWidgetKind: String, Codable, CaseIterable, Identifiable {
    // Original
    case clock, date, cpu, memory, battery, disk, timer, audioOutput, nowPlaying
    // Added in 3.0
    case analogClock, worldClock, calendar, gpu, network, ip, peripherals, thermal,
         volume, keyboardLayout, caffeine, countdown, weather

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clock: return "Clock"
        case .analogClock: return "Analogue Clock"
        case .worldClock: return "World Clock"
        case .date: return "Date"
        case .calendar: return "Month Calendar"
        case .cpu: return "CPU Load"
        case .memory: return "Memory Used"
        case .gpu: return "GPU Load"
        case .battery: return "Battery"
        case .disk: return "Disk Used"
        case .network: return "Network Speed"
        case .ip: return "IP Address"
        case .peripherals: return "Device Batteries"
        case .thermal: return "Thermal State"
        case .timer: return "Stopwatch"
        case .countdown: return "Countdown Timer"
        case .audioOutput: return "Audio Output"
        case .nowPlaying: return "Now Playing"
        case .volume: return "Volume"
        case .keyboardLayout: return "Keyboard Layout"
        case .caffeine: return "Keep Awake"
        case .weather: return "Weather"
        }
    }

    var blurb: String {
        switch self {
        case .clock: return "The time, to the minute or the second."
        case .analogClock: return "A clock face that moves its hands."
        case .worldClock: return "The time in another city."
        case .date: return "Today's weekday and date."
        case .calendar: return "Today's date — click for the whole month."
        case .cpu: return "How hard the processor is working."
        case .memory: return "How much memory is in use."
        case .gpu: return "How hard the graphics processor is working."
        case .battery: return "Charge, charging state and time left."
        case .disk: return "How full your startup disk is."
        case .network: return "Live download and upload speed."
        case .ip: return "Your local and public IP, click to copy."
        case .peripherals: return "Battery of your keyboard, mouse and trackpad."
        case .thermal: return "Whether the Mac is running hot."
        case .timer: return "Click to start, pause and reset."
        case .countdown: return "A focus timer with a progress ring."
        case .audioOutput: return "Pick where sound comes out."
        case .nowPlaying: return "What Music or Spotify is playing."
        case .volume: return "System volume — scroll to change it."
        case .keyboardLayout: return "Your current input language, click to switch."
        case .caffeine: return "Stops the Mac from sleeping."
        case .weather: return "Temperature where you are."
        }
    }

    var symbol: String {
        switch self {
        case .clock: return "clock"
        case .analogClock: return "clock.fill"
        case .worldClock: return "globe"
        case .date: return "calendar"
        case .calendar: return "calendar.badge.clock"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "display"
        case .battery: return "battery.100"
        case .disk: return "internaldrive"
        case .network: return "arrow.up.arrow.down"
        case .ip: return "network"
        case .peripherals: return "keyboard.badge.ellipsis"
        case .thermal: return "thermometer.medium"
        case .timer: return "stopwatch"
        case .countdown: return "timer"
        case .audioOutput: return "hifispeaker"
        case .nowPlaying: return "music.note"
        case .volume: return "speaker.wave.2"
        case .keyboardLayout: return "keyboard"
        case .caffeine: return "cup.and.saucer"
        case .weather: return "cloud.sun"
        }
    }

    enum Category: String, CaseIterable, Identifiable {
        case system = "System", time = "Time", network = "Network", media = "Sound & Media", tools = "Tools"
        var id: String { rawValue }
    }

    var category: Category {
        switch self {
        case .cpu, .memory, .gpu, .battery, .disk, .thermal, .peripherals: return .system
        case .clock, .analogClock, .worldClock, .date, .calendar, .timer, .countdown: return .time
        case .network, .ip, .weather: return .network
        case .audioOutput, .nowPlaying, .volume: return .media
        case .keyboardLayout, .caffeine: return .tools
        }
    }

    /// Whether this widget talks to the internet. Surfaced in the gallery so a
    /// widget that makes requests never does so without the user knowing.
    var usesInternet: Bool { self == .weather || self == .ip }

    /// Whether the widget has a graph variant.
    var supportsGraph: Bool { [.cpu, .memory, .gpu, .network].contains(self) }

    /// Whether it's a click target rather than a pure readout.
    var isInteractive: Bool {
        [.timer, .countdown, .nowPlaying, .audioOutput, .volume, .keyboardLayout, .caffeine, .calendar, .ip].contains(self)
    }
}

enum WidgetStyle: String, Codable, CaseIterable, Identifiable {
    case compact, graph
    var id: String { rawValue }
    var label: String { self == .compact ? "Number" : "Graph" }
}

enum IPDisplayMode: String, Codable, CaseIterable, Identifiable {
    case local, publicAddress, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .local: return "Local"
        case .publicAddress: return "Public"
        case .both: return "Both"
        }
    }
}

/// Per-tile settings for widgets that have any.
struct WidgetOptions: Codable, Equatable {
    var style: WidgetStyle = .compact
    var showsSeconds = false
    /// `nil` follows the system's 12/24-hour setting.
    var use24Hour: Bool?
    /// World clock: an IANA identifier such as "Asia/Tokyo".
    var timeZoneID = ""
    /// Countdown length.
    var countdownMinutes = 25
    // Weather
    var city = ""
    var latitude: Double?
    var longitude: Double?
    var fahrenheit = false
    var ipMode: IPDisplayMode = .local

    init() {}

    private enum CodingKeys: String, CodingKey {
        case style, showsSeconds, use24Hour, timeZoneID, countdownMinutes, city, latitude, longitude, fahrenheit, ipMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = c.value(.style, WidgetStyle.compact)
        showsSeconds = c.value(.showsSeconds, false)
        use24Hour = try? c.decodeIfPresent(Bool.self, forKey: .use24Hour)
        timeZoneID = String(c.value(.timeZoneID, "").prefix(64))
        countdownMinutes = min(max(c.value(.countdownMinutes, 25), 1), 600)
        city = String(c.value(.city, "").prefix(80))
        latitude = (try? c.decodeIfPresent(Double.self, forKey: .latitude)).flatMap { $0.isFinite && abs($0) <= 90 ? $0 : nil }
        longitude = (try? c.decodeIfPresent(Double.self, forKey: .longitude)).flatMap { $0.isFinite && abs($0) <= 180 ? $0 : nil }
        fahrenheit = c.value(.fahrenheit, false)
        ipMode = c.value(.ipMode, IPDisplayMode.local)
    }
}

/// Everything a widget face needs to draw itself, as plain values. Equality
/// drives redraws: a face is re-rendered only when its snapshot changes.
struct WidgetSnapshot: Equatable {
    enum Tone: Equatable { case normal, good, warning, critical, dim }

    var caption = ""
    var primary = ""
    var secondary = ""
    var symbol: String?
    /// 0…1 gauge fill.
    var fraction: Double?
    /// 0…1 samples, oldest first, for graph styles.
    var history: [Double] = []
    var tone: Tone = .normal
    var lines: [String] = []
    /// Drives analogue faces, where the *time* is the content.
    var date: Date?
}
