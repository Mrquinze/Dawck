import SwiftUI
import AppKit

/// Draws a widget from its snapshot.
///
/// A face is a pure function of plain values, rendered to a bitmap when — and
/// only when — its snapshot changes. The old widgets were live SwiftUI views
/// observing shared objects, so every metric tick re-evaluated every widget in
/// every dock and re-laid-out the row around them.
struct WidgetFace: View {
    let kind: DockWidgetKind
    let snapshot: WidgetSnapshot
    let options: WidgetOptions
    let side: CGFloat
    let foreground: Color
    let accent: Color

    private var toneColor: Color {
        switch snapshot.tone {
        case .normal: return accent
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        case .dim: return foreground.opacity(0.45)
        }
    }

    private func font(_ scale: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: side * scale, weight: weight, design: .rounded)
    }

    var body: some View {
        ZStack { content }
            .frame(width: side, height: side)
            .foregroundStyle(foreground)
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .clock:
            VStack(spacing: side * 0.02) {
                Text(snapshot.primary).font(font(options.showsSeconds ? 0.21 : 0.29)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                if !snapshot.secondary.isEmpty {
                    Text(snapshot.secondary).font(font(0.13, .medium)).opacity(0.6)
                }
            }
        case .worldClock:
            VStack(spacing: side * 0.03) {
                Text(snapshot.caption).font(font(0.15, .medium)).opacity(0.65).lineLimit(1).minimumScaleFactor(0.5)
                Text(snapshot.primary).font(font(0.27)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            }
        case .analogClock:
            AnalogClockFace(date: snapshot.date ?? Date(), showsSeconds: options.showsSeconds,
                            foreground: foreground, accent: accent)
                .padding(side * 0.08)
        case .date, .calendar:
            VStack(spacing: 0) {
                Text(snapshot.caption.uppercased()).font(font(0.15, .bold)).foregroundStyle(Color.red)
                Text(snapshot.primary).font(font(0.46, .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            }
        case .cpu, .memory, .gpu, .disk, .battery:
            GaugeContent(snapshot: snapshot, options: options, side: side, color: toneColor, foreground: foreground,
                         supportsGraph: kind.supportsGraph)
        case .network:
            if options.style == .graph, snapshot.history.count > 1 {
                ZStack {
                    Sparkline(values: snapshot.history, color: toneColor).padding(side * 0.12)
                    Text(snapshot.primary).font(font(0.17, .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                }
            } else {
                VStack(spacing: side * 0.05) {
                    ForEach(Array(snapshot.lines.prefix(2).enumerated()), id: \.offset) { _, line in
                        Text(line).font(font(0.16, .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    }
                }.padding(.horizontal, side * 0.06)
            }
        case .ip:
            VStack(spacing: side * 0.05) {
                Text(snapshot.caption).font(font(0.13, .bold)).opacity(0.6)
                ForEach(Array(snapshot.lines.prefix(2).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: side * 0.15, weight: .semibold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.4)
                }
            }.padding(.horizontal, side * 0.05)
        case .peripherals:
            VStack(spacing: side * 0.05) {
                if snapshot.lines.isEmpty {
                    Image(systemName: "keyboard.badge.ellipsis").font(.system(size: side * 0.36)).opacity(0.5)
                } else {
                    ForEach(Array(snapshot.lines.prefix(3).enumerated()), id: \.offset) { _, line in
                        let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
                        HStack(spacing: side * 0.05) {
                            Image(systemName: parts.first ?? "circle").font(.system(size: side * 0.17))
                            Text(parts.count > 1 ? parts[1] : "").font(font(0.17)).monospacedDigit()
                        }
                    }
                }
            }
        case .thermal:
            VStack(spacing: side * 0.04) {
                Image(systemName: snapshot.symbol ?? "thermometer.medium").font(.system(size: side * 0.34))
                    .foregroundStyle(toneColor)
                Text(snapshot.primary).font(font(0.16)).lineLimit(1).minimumScaleFactor(0.5)
            }
        case .volume:
            VStack(spacing: side * 0.05) {
                Image(systemName: snapshot.symbol ?? "speaker.wave.2").font(.system(size: side * 0.3))
                Text(snapshot.primary).font(font(0.2)).monospacedDigit()
                GaugeBar(fraction: snapshot.fraction ?? 0, color: toneColor, foreground: foreground)
                    .frame(width: side * 0.6, height: max(3, side * 0.06))
            }
        case .keyboardLayout:
            VStack(spacing: side * 0.02) {
                Text(snapshot.primary).font(font(0.34, .bold)).lineLimit(1).minimumScaleFactor(0.5)
                Text(snapshot.caption).font(font(0.12, .medium)).opacity(0.6).lineLimit(1).minimumScaleFactor(0.5)
            }.padding(.horizontal, side * 0.05)
        case .caffeine:
            VStack(spacing: side * 0.04) {
                Image(systemName: snapshot.symbol ?? "cup.and.saucer").font(.system(size: side * 0.38))
                    .foregroundStyle(snapshot.tone == .good ? Color.orange : foreground)
                Text(snapshot.caption).font(font(0.12, .semibold)).opacity(0.7)
            }
        case .weather:
            VStack(spacing: side * 0.02) {
                Image(systemName: snapshot.symbol ?? "cloud.sun").symbolRenderingMode(.multicolor)
                    .font(.system(size: side * 0.3))
                Text(snapshot.primary).font(font(0.24)).monospacedDigit()
                Text(snapshot.caption).font(font(0.11, .medium)).opacity(0.6).lineLimit(1).minimumScaleFactor(0.5)
            }.padding(.horizontal, side * 0.05)
        case .timer:
            VStack(spacing: side * 0.04) {
                Text(snapshot.primary).font(font(0.24)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                Image(systemName: snapshot.symbol ?? "play.fill").font(.system(size: side * 0.18)).opacity(0.65)
            }
        case .countdown:
            ZStack {
                Circle().stroke(foreground.opacity(0.15), lineWidth: side * 0.07)
                Circle().trim(from: 0, to: CGFloat(snapshot.fraction ?? 0))
                    .stroke(toneColor, style: StrokeStyle(lineWidth: side * 0.07, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(snapshot.primary).font(font(0.2)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                    Image(systemName: snapshot.symbol ?? "play.fill").font(.system(size: side * 0.12)).opacity(0.6)
                }
            }.padding(side * 0.12)
        case .audioOutput:
            VStack(spacing: side * 0.05) {
                Image(systemName: snapshot.symbol ?? "hifispeaker.fill").font(.system(size: side * 0.32))
                Text(snapshot.caption).font(font(0.14, .medium)).lineLimit(1).minimumScaleFactor(0.5)
            }.padding(.horizontal, side * 0.05)
        case .nowPlaying:
            VStack(spacing: side * 0.03) {
                Image(systemName: snapshot.symbol ?? "music.note").font(.system(size: side * 0.28))
                    .foregroundStyle(snapshot.tone == .good ? accent : foreground)
                Text(snapshot.primary.isEmpty ? "Nothing" : snapshot.primary)
                    .font(font(0.14, .semibold)).lineLimit(1).minimumScaleFactor(0.5)
                if !snapshot.secondary.isEmpty {
                    Text(snapshot.secondary).font(font(0.11, .regular)).opacity(0.6).lineLimit(1).minimumScaleFactor(0.5)
                }
            }.padding(.horizontal, side * 0.05)
        }
    }
}

private struct GaugeContent: View {
    let snapshot: WidgetSnapshot
    let options: WidgetOptions
    let side: CGFloat
    let color: Color
    let foreground: Color
    let supportsGraph: Bool

    var body: some View {
        if options.style == .graph, supportsGraph, snapshot.history.count > 1 {
            ZStack(alignment: .top) {
                Sparkline(values: snapshot.history, color: color).padding(.horizontal, side * 0.1).padding(.top, side * 0.3).padding(.bottom, side * 0.12)
                VStack(spacing: 0) {
                    Text(snapshot.caption).font(.system(size: side * 0.13, weight: .bold, design: .rounded)).opacity(0.6)
                    Text(snapshot.primary).font(.system(size: side * 0.2, weight: .semibold, design: .rounded)).monospacedDigit()
                }.padding(.top, side * 0.06)
            }
        } else {
            VStack(spacing: side * 0.04) {
                HStack(spacing: side * 0.03) {
                    if let symbol = snapshot.symbol { Image(systemName: symbol).font(.system(size: side * 0.16)) }
                    Text(snapshot.primary).font(.system(size: side * 0.3, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
                GaugeBar(fraction: snapshot.fraction ?? 0, color: color, foreground: foreground)
                    .frame(width: side * 0.62, height: max(3, side * 0.06))
                Text(snapshot.caption).font(.system(size: side * 0.14, weight: .medium)).opacity(0.6)
                    .lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, side * 0.04)
            }
        }
    }
}

private struct GaugeBar: View {
    let fraction: Double
    let color: Color
    let foreground: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(foreground.opacity(0.15))
                Capsule().fill(color).frame(width: max(proxy.size.height, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(min(max(value, 0), 1))))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.45), color.opacity(0.02)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct AnalogClockFace: View {
    let date: Date
    let showsSeconds: Bool
    let foreground: Color
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side / 2
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(foreground.opacity(0.35)), lineWidth: max(1, side * 0.03))
            for tick in 0..<12 {
                let angle = Double(tick) / 12 * 2 * .pi
                let long = tick % 3 == 0
                var path = Path()
                path.move(to: CGPoint(x: center.x + CGFloat(sin(angle)) * radius * (long ? 0.72 : 0.82),
                                      y: center.y - CGFloat(cos(angle)) * radius * (long ? 0.72 : 0.82)))
                path.addLine(to: CGPoint(x: center.x + CGFloat(sin(angle)) * radius * 0.92,
                                         y: center.y - CGFloat(cos(angle)) * radius * 0.92))
                context.stroke(path, with: .color(foreground.opacity(long ? 0.9 : 0.5)),
                               style: StrokeStyle(lineWidth: max(1, side * (long ? 0.035 : 0.02)), lineCap: .round))
            }
            let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
            let minute = Double(comps.minute ?? 0), hour = Double(comps.hour ?? 0).truncatingRemainder(dividingBy: 12)
            let second = Double(comps.second ?? 0)
            func hand(_ angle: Double, _ length: CGFloat, _ width: CGFloat, _ color: Color) {
                var path = Path()
                path.move(to: center)
                path.addLine(to: CGPoint(x: center.x + CGFloat(sin(angle)) * radius * length,
                                         y: center.y - CGFloat(cos(angle)) * radius * length))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            hand((hour + minute / 60) / 12 * 2 * .pi, 0.5, max(2, side * 0.06), foreground)
            hand(minute / 60 * 2 * .pi, 0.74, max(1.5, side * 0.045), foreground)
            if showsSeconds { hand(second / 60 * 2 * .pi, 0.82, max(1, side * 0.02), accent) }
            context.fill(Path(ellipseIn: CGRect(x: center.x - side * 0.04, y: center.y - side * 0.04, width: side * 0.08, height: side * 0.08)),
                         with: .color(accent))
        }
    }
}

enum WidgetFaceRenderer {
    /// Renders a face at `side` points and `scale` pixels per point.
    @MainActor
    static func image(kind: DockWidgetKind, snapshot: WidgetSnapshot, options: WidgetOptions,
                      side: CGFloat, scale: CGFloat, dark: Bool, foreground: Color, accent: Color) -> CGImage? {
        let face = WidgetFace(kind: kind, snapshot: snapshot, options: options, side: side,
                              foreground: foreground, accent: accent)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: face)
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }
}
