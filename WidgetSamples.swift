import Foundation

/// Fixed example readings for the widget gallery, so browsing widgets costs no
/// sampling at all — nothing is measured until a widget is on a dock.
enum WidgetSamples {
    static func snapshot(for kind: DockWidgetKind) -> WidgetSnapshot {
        var s = WidgetSnapshot()
        var wave: [Double] = []
        for i in 0..<24 {
            let x = Double(i)
            wave.append(0.35 + 0.25 * sin(x / 3.0) + 0.1 * sin(x / 1.3))
        }
        switch kind {
        case .clock: s.primary = "9:41"; s.secondary = "Mon 9 Nov"
        case .analogClock: s.date = Calendar.current.date(from: DateComponents(hour: 10, minute: 9, second: 30))
        case .worldClock: s.primary = "18:41"; s.caption = "Tokyo"
        case .date, .calendar: s.caption = "Mon"; s.primary = "9"
        case .cpu: s.primary = "34%"; s.caption = "CPU"; s.fraction = 0.34; s.history = wave
        case .memory: s.primary = "62%"; s.caption = "RAM"; s.fraction = 0.62; s.history = wave
        case .gpu: s.primary = "21%"; s.caption = "GPU"; s.fraction = 0.21; s.history = wave
        case .battery: s.primary = "87%"; s.caption = "3:12 left"; s.fraction = 0.87
        case .disk: s.primary = "71%"; s.caption = "SSD"; s.fraction = 0.71
        case .network: s.lines = ["↓ 3.2 MB/s", "↑ 180 KB/s"]; s.primary = "3.4 MB/s"; s.history = wave
        case .ip: s.caption = "LOCAL"; s.lines = ["192.168.1.24"]
        case .peripherals: s.lines = ["keyboard|82%", "computermouse|64%"]
        case .thermal: s.primary = "Cool"; s.symbol = "thermometer.low"; s.tone = .good
        case .timer: s.primary = "12:08"; s.symbol = "pause.fill"
        case .countdown: s.primary = "18:20"; s.fraction = 0.73; s.symbol = "pause.fill"
        case .audioOutput: s.caption = "MacBook Speakers"; s.symbol = "hifispeaker.fill"
        case .nowPlaying: s.primary = "Blue in Green"; s.secondary = "Miles Davis"; s.symbol = "waveform"; s.tone = .good
        case .volume: s.primary = "55%"; s.fraction = 0.55; s.symbol = "speaker.wave.2.fill"
        case .keyboardLayout: s.primary = "EN"; s.caption = "U.S."
        case .caffeine: s.symbol = "cup.and.saucer.fill"; s.caption = "AWAKE"; s.tone = .good
        case .weather: s.primary = "21°"; s.symbol = "cloud.sun.fill"; s.caption = "Lisbon"
        }
        return s
    }
}
