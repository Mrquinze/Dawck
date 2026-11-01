import SwiftUI
import AppKit
import QuartzCore

// MARK: - Liquid Glass helpers

/// Dawck's settings use Apple's Liquid Glass where the OS has it (macOS 26+) and
/// a close material stand-in where it does not, so the same layout reads
/// correctly on macOS 14 and 15.
extension View {
    /// A rounded glass card. `interactive` makes it respond to the pointer
    /// (macOS 26+ only; elsewhere it is simply a card).
    @ViewBuilder
    func glassCard(radius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = {
                var base = Glass.regular
                if let tint { base = base.tint(tint) }
                return interactive ? base.interactive() : base
            }()
            self.glassEffect(glass, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 0.5) }
        }
    }

    /// The glass button style on macOS 26+, the closest classic one before that.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }

    /// A capsule-shaped glass chip, for tags and small pickers.
    @ViewBuilder
    func glassChip(selected: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Capsule())
        } else {
            self.background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.35)) : AnyShapeStyle(.thinMaterial), in: Capsule())
        }
    }
}

/// Merges neighbouring glass shapes the way Liquid Glass is meant to be used,
/// and costs nothing on systems without it.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// The quiet colour wash behind a settings pane. Static: it is a handful of
/// gradients drawn once, so it adds nothing to scrolling or slider drags.
struct AmbientBackdrop: View {
    var tint: Color = .accentColor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            RadialGradient(colors: [tint.opacity(scheme == .dark ? 0.22 : 0.16), .clear], center: .topLeading, startRadius: 20, endRadius: 520)
            RadialGradient(colors: [Color.purple.opacity(scheme == .dark ? 0.14 : 0.10), .clear], center: .bottomTrailing, startRadius: 20, endRadius: 560)
        }
        .ignoresSafeArea()
        .drawingGroup(opaque: true)
    }
}

/// A titled block on a glass card.
struct GlassSection<Content: View>: View {
    let title: String
    var symbol: String?
    var footnote: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
                Text(title).font(.headline)
            }
            content()
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 22)
    }
}

/// A label with its control on the right, for rows inside a `GlassSection`.
struct GlassRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).frame(minWidth: 120, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Sliders

/// A slider that writes at most ~30 times a second while it is dragged, and
/// exactly once more when it is released.
///
/// Every value written to a store reaches every dock and every observing view;
/// a drag used to produce hundreds of writes a second, each of which rebuilt
/// the settings screen and re-encoded the whole configuration.
struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: String = "%.0f"

    @State private var local: Double = 0
    @State private var isDragging = false
    @State private var lastPush: CFTimeInterval = 0
    @State private var pending: DispatchWorkItem?

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: Binding(get: { isDragging ? local : value }, set: { newValue in
                local = newValue
                push()
            }), in: range, step: step) { editing in
                if editing {
                    local = value
                    isDragging = true
                } else {
                    commit()
                    isDragging = false
                }
            }
            Text(String(format: format, isDragging ? local : value))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func push() {
        let now = CACurrentMediaTime()
        if now - lastPush >= 0.033 {
            commit()
        } else if pending == nil {
            let work = DispatchWorkItem { commit() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.033, execute: work)
        }
    }

    private func commit() {
        pending?.cancel()
        pending = nil
        lastPush = CACurrentMediaTime()
        if value != local { value = local }
    }
}

// MARK: - Colour well

/// A colour picker that doesn't flood its binding while the system colour
/// panel is being dragged.
struct ThrottledColorPicker: View {
    let title: String
    @Binding var color: CodableColor
    var supportsOpacity = false

    @State private var pending: DispatchWorkItem?

    var body: some View {
        ColorPicker(title, selection: Binding(get: { color.color }, set: { newValue in
            pending?.cancel()
            let work = DispatchWorkItem { color = CodableColor(color: newValue) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
        }), supportsOpacity: supportsOpacity)
    }
}
