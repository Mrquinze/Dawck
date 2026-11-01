import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The theme customiser. Every control writes into the active theme, and the
/// preview renders with the same layer-based surface the real docks use, so what
/// is on screen here is not an approximation.
struct ThemeSettingsView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @ObservedObject private var systemGlass = SystemGlass.shared
    @State private var saveName = ""
    @State private var isNamingSave = false
    @State private var importMessage: String?

    private var theme: Binding<GlassTheme> {
        Binding(get: { themeStore.active }, set: { themeStore.active = $0 })
    }

    private func field<T>(_ keyPath: WritableKeyPath<GlassTheme, T>) -> Binding<T> {
        Binding(get: { themeStore.active[keyPath: keyPath] }, set: { themeStore.active[keyPath: keyPath] = $0 })
    }

    private var fill: ThemeFillStyle { themeStore.active.fillStyle }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ThemePreview(theme: themeStore.active)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                designsSection
                paletteSection
                fillSection
                if fill != .native { materialSection; opticsSection; colourPlaySection }
                tilesSection
                shapeSection
                savedSection
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .background { AmbientBackdrop(tint: themeStore.active.tint.color) }
    }

    // MARK: Designs

    private var designsSection: some View {
        GlassSection(title: "Designs", symbol: "square.stack.3d.up",
                     footnote: "A design is the shape and feel of the dock. Palettes below change only the colours, so any design can wear any palette.") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(GlassTheme.allPresets) { preset in
                        PresetSwatch(theme: preset, isSelected: themeStore.active.name == preset.name) {
                            // Copied, not referenced — editing after picking a
                            // preset must never mutate the preset itself.
                            themeStore.active = preset.asEditableCopy()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Palette

    private var paletteSection: some View {
        GlassSection(title: "Palette", symbol: "paintpalette") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(ColorPalette.all) { palette in
                        PaletteChip(palette: palette, isSelected: isSelected(palette)) {
                            themeStore.active = themeStore.active.applying(palette)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            PaletteEditor(theme: theme)
        }
    }

    private func isSelected(_ palette: ColorPalette) -> Bool {
        let stops = themeStore.active.tintStops
        return stops.count == palette.colors.count && zip(stops, palette.colors).allSatisfy { $0 == $1 }
    }

    // MARK: Fill

    private var fillSection: some View {
        GlassSection(title: "Surface", symbol: "drop.halffull", footnote: fillExplanation) {
            Picker("Fill", selection: field(\.fillStyle)) {
                ForEach(ThemeFillStyle.allCases) { style in
                    if style != .native || SystemGlassAvailability.isSupported {
                        Label(style.label, systemImage: style.symbol).tag(style)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if fill == .native {
                GlassRow(label: "Glass") {
                    Picker("", selection: field(\.nativeVariant)) {
                        ForEach(NativeGlassVariant.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                Toggle("React to the pointer (macOS 27)", isOn: field(\.nativeInteractive))
            }
            Toggle("Follow the system Liquid Glass setting", isOn: field(\.followsSystemGlass))
            if themeStore.active.followsSystemGlass {
                Text(SystemGlassAvailability.isMacOS27
                     ? "System Settings → Appearance currently sits at \(Int(systemGlass.amount * 100))% between clear and opaque. This dock moves with it."
                     : "macOS 27 adds a system-wide clear↔opaque Liquid Glass slider; once you have it, this dock moves with it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var fillExplanation: String {
        switch fill {
        case .glass: return "Dawck's own layered glass: blurred backdrop, tint, depth, edge lensing, a highlight that follows the pointer, grain and a rim light."
        case .gradient: return "A palette painted straight onto the plate, like Goorgle's gradient mode. Raise the intensity for a solid colour, lower it to let the desktop through."
        case .native: return "Apple's own Liquid Glass. It draws its own edge and refraction, so the optics controls are hidden; only the shape and elevation apply."
        }
    }

    // MARK: Material, optics, colour

    private var materialSection: some View {
        GlassSection(title: fill == .glass ? "Material" : "Colour", symbol: "square.3.layers.3d.down.right") {
            if fill == .glass {
                GlassRow(label: "Substrate") {
                    Picker("", selection: field(\.substrate)) { ForEach(GlassSubstrate.allCases) { Text($0.label).tag($0) } }.labelsHidden()
                }
            }
            GlassRow(label: "Appearance") {
                Picker("", selection: field(\.appearance)) { ForEach(GlassAppearance.allCases) { Text($0.label).tag($0) } }.labelsHidden()
            }
            GlassRow(label: "Translucency") { ValueSlider(value: field(\.translucency), range: 0.15...1, step: 0.01, format: "%.2f") }
            GlassRow(label: fill == .gradient ? "Colour Strength" : "Tint Strength") {
                ValueSlider(value: field(\.tintIntensity), range: 0...1, step: 0.01, format: "%.2f")
            }
            GlassRow(label: "Text & Glyphs") {
                Picker("", selection: field(\.textColorMode)) { ForEach(TextColorMode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
        }
    }

    private var opticsSection: some View {
        GlassSection(title: "Optics", symbol: "light.max",
                     footnote: "The highlight follows your pointer across the dock — that motion is what makes glass read as glass rather than as a flat panel.") {
            GlassRow(label: "Specular Highlight") { ValueSlider(value: field(\.specularIntensity), range: 0...1, step: 0.01, format: "%.2f") }
            GlassRow(label: "Highlight Spread") { ValueSlider(value: field(\.specularSpread), range: 0.2...2, step: 0.01, format: "%.2f") }
            GlassRow(label: "Edge Lensing") { ValueSlider(value: field(\.lensing), range: 0...1, step: 0.01, format: "%.2f") }
            GlassRow(label: "Rim Light") { ValueSlider(value: field(\.rimIntensity), range: 0...1, step: 0.01, format: "%.2f") }
            GlassRow(label: "Rim Width") { ValueSlider(value: field(\.rimWidth), range: 0...4, step: 0.1, format: "%.1f px") }
            GlassRow(label: "Depth Falloff") { ValueSlider(value: field(\.depth), range: 0...1, step: 0.01, format: "%.2f") }
            GlassRow(label: "Frosted Grain") { ValueSlider(value: field(\.grain), range: 0...0.6, step: 0.01, format: "%.2f") }
        }
    }

    private var colourPlaySection: some View {
        GlassSection(title: "Colour Play", symbol: "wand.and.stars") {
            ThrottledColorPicker(title: "Rim & Edge Light", color: field(\.rimColor))
            ThrottledColorPicker(title: "Outer Glow", color: field(\.glowColor))
            GlassRow(label: "Glow Strength") { ValueSlider(value: field(\.glowIntensity), range: 0...1, step: 0.01, format: "%.2f") }
            ThrottledColorPicker(title: "Shadow", color: field(\.shadowColor))
            GlassRow(label: "Hue Drift") { ValueSlider(value: field(\.tintCycleSeconds), range: 0...300, step: 5, format: "%.0f s") }
            Text(themeStore.active.tintCycleSeconds < 1 ? "Off — the tint holds still."
                 : "The tint travels once around the colour wheel every \(Int(themeStore.active.tintCycleSeconds)) seconds. Long cycles read as the light changing rather than as an animation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Tiles, shape

    private var tilesSection: some View {
        GlassSection(title: "Tiles & Icons", symbol: "app.dashed") {
            GlassRow(label: "Tile Backing") {
                Picker("", selection: field(\.tileShape)) { ForEach(TileShape.allCases) { Text($0.label).tag($0) } }.labelsHidden()
            }
            GlassRow(label: "Backing Opacity") { ValueSlider(value: field(\.tileBackingOpacity), range: 0...0.5, step: 0.01, format: "%.2f") }
            GlassRow(label: "Icon Saturation") { ValueSlider(value: field(\.iconSaturation), range: 0...2, step: 0.05, format: "%.2f") }
            Text("Backing is the plate behind action, widget, group and tray tiles; app icons keep their own shape. Saturation 0 renders icons greyscale, 1 leaves them alone.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var shapeSection: some View {
        GlassSection(title: "Shape & Elevation", symbol: "rectangle.roundedtop") {
            Toggle("Pill (fully rounded ends)", isOn: field(\.capsule))
            if !themeStore.active.capsule {
                GlassRow(label: "Corner Radius") { ValueSlider(value: field(\.cornerRadius), range: 0...44, step: 1, format: "%.0f pt") }
            }
            Toggle("Continuous (squircle) corners", isOn: field(\.continuousCorners))
            GlassRow(label: "Inner Padding") { ValueSlider(value: field(\.padding), range: 0...28, step: 1, format: "%.0f pt") }
            GlassRow(label: "Shadow Radius") { ValueSlider(value: field(\.shadowRadius), range: 0...50, step: 1, format: "%.0f pt") }
            GlassRow(label: "Shadow Strength") { ValueSlider(value: field(\.shadowOpacity), range: 0...1, step: 0.01, format: "%.2f") }
            GlassRow(label: "Shadow Offset") { ValueSlider(value: field(\.shadowYOffset), range: -20...30, step: 1, format: "%.0f pt") }
        }
    }

    // MARK: Saved

    private var savedSection: some View {
        GlassSection(title: "Saved Themes", symbol: "tray.full",
                     footnote: themeStore.saved.isEmpty ? "Save the current look to reuse it, or to give one dock a different look than the rest." : nil) {
            ForEach(themeStore.saved) { saved in
                HStack(spacing: 12) {
                    GlassSwatch(theme: saved, scale: 0.5).frame(width: 54, height: 26)
                    Text(saved.name)
                    Spacer()
                    Button("Use") { themeStore.apply(saved) }.glassButtonStyle()
                    Button { export(saved) } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.borderless).help("Export as a file")
                    Button(role: .destructive) { themeStore.delete(saved) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            if isNamingSave {
                HStack {
                    TextField("Theme name", text: $saveName).onSubmit(commitSave)
                    Button("Save", action: commitSave).disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty).glassButtonStyle(prominent: true)
                    Button("Cancel") { isNamingSave = false; saveName = "" }.glassButtonStyle()
                }
            } else {
                HStack {
                    Button("Save Current Theme…") { saveName = themeStore.active.name; isNamingSave = true }.glassButtonStyle(prominent: true)
                    Button("Import Theme…") { importTheme() }.glassButtonStyle()
                    Button("Export Current…") { export(themeStore.active) }.glassButtonStyle()
                }
            }
            if let importMessage { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func commitSave() {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        themeStore.saveCurrentAsNew(named: name)
        themeStore.active.name = name
        saveName = ""
        isNamingSave = false
    }

    private func export(_ theme: GlassTheme) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(theme.name).dawcktheme.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try encoder.encode(theme).write(to: url, options: .atomic); importMessage = "Exported “\(theme.name)”." }
        catch { importMessage = "Couldn't export: \(error.localizedDescription)" }
    }

    /// Imported files are treated as untrusted: size-capped, decoded through the
    /// forgiving decoder (which clamps every number), and given a fresh identity.
    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 256 * 1024,
              let data = try? Data(contentsOf: url), var imported = try? JSONDecoder().decode(GlassTheme.self, from: data) else {
            importMessage = "That file isn't a Dawck theme."
            return
        }
        imported.id = UUID()
        imported.name = String(imported.name.prefix(60))
        themeStore.saved.append(imported)
        importMessage = "Imported “\(imported.name)”. Use it from the list above."
    }
}

// MARK: - Palette editor

/// Edits the stops of the active palette: up to five colours and the angle they
/// run at, as Goorgle's editor does.
private struct PaletteEditor: View {
    @Binding var theme: GlassTheme

    private var stops: [CodableColor] { theme.tintStops }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Array(stops.enumerated()), id: \.offset) { index, _ in
                    VStack(spacing: 4) {
                        ThrottledColorPicker(title: "", color: Binding(
                            get: { theme.tintStops.indices.contains(index) ? theme.tintStops[index] : CodableColor() },
                            set: { setStop(index, $0) }
                        ))
                        .labelsHidden()
                        if stops.count > 1 {
                            Button { remove(index) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                }
                if stops.count < 5 {
                    Button { add() } label: { Image(systemName: "plus.circle.fill").font(.title2) }.buttonStyle(.borderless)
                        .help("Add a colour")
                }
                Spacer()
                Capsule()
                    .fill(LinearGradient(colors: stops.map(\.color), startPoint: .leading, endPoint: .trailing))
                    .frame(width: 120, height: 14)
            }
            if stops.count > 1 {
                GlassRow(label: "Angle") { ValueSlider(value: $theme.tintAngle, range: 0...360, step: 5, format: "%.0f°") }
            }
        }
    }

    private func setStop(_ index: Int, _ color: CodableColor) {
        var updated = theme.tintStops
        guard updated.indices.contains(index) else { return }
        updated[index] = color
        theme.setStops(updated)
    }

    private func add() {
        var updated = theme.tintStops
        updated.append(updated.last.map { $0.hueRotated(by: 0.18) } ?? CodableColor(hex: "FF6B6B"))
        theme.setStops(updated)
    }

    private func remove(_ index: Int) {
        var updated = theme.tintStops
        guard updated.count > 1, updated.indices.contains(index) else { return }
        updated.remove(at: index)
        theme.setStops(updated)
    }
}

// MARK: - Pieces

private struct PresetSwatch: View {
    let theme: GlassTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    PreviewBackdrop()
                    GlassSwatch(theme: theme, scale: 0.7).frame(width: 76, height: 38)
                }
                .frame(width: 100, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5) }
                Text(theme.name).font(.caption).foregroundStyle(isSelected ? Color.accentColor : .secondary).lineLimit(1)
            }
            .frame(width: 100)
        }
        .buttonStyle(.plain)
    }
}

private struct PaletteChip: View {
    let palette: ColorPalette
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Capsule()
                    .fill(LinearGradient(colors: palette.colors.map(\.color), startPoint: .leading, endPoint: .trailing))
                    .frame(width: 84, height: 26)
                    .overlay { Capsule().strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.18), lineWidth: isSelected ? 2.5 : 0.5) }
                Text(palette.name).font(.caption2).foregroundStyle(isSelected ? Color.accentColor : .secondary).lineLimit(1)
            }
            .frame(width: 88)
        }
        .buttonStyle(.plain)
    }
}

/// A synthetic desktop for previews. Themes are judged against a wallpaper in
/// real use, so previewing them on a flat grey would misrepresent every
/// translucency and substrate setting.
struct PreviewBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.20, blue: 0.42), Color(red: 0.53, green: 0.26, blue: 0.52), Color(red: 0.94, green: 0.55, blue: 0.35)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                // Soft blooms give the blur structure to sample; a pure linear
                // gradient blurs to an indistinguishable wash.
                GeometryReader { proxy in
                    let w = proxy.size.width, h = proxy.size.height
                    Circle().fill(.white.opacity(0.22)).frame(width: w * 0.5).blur(radius: 40).offset(x: w * 0.12, y: -h * 0.18)
                    Circle().fill(Color(red: 0.1, green: 0.9, blue: 0.8).opacity(0.28)).frame(width: w * 0.4).blur(radius: 46).offset(x: w * 0.55, y: h * 0.5)
                }
            }
    }
}

/// The big live preview: a stand-in desktop with a sample dock drawn by the same
/// renderer the real docks use.
struct ThemePreview: NSViewRepresentable {
    let theme: GlassTheme

    func makeNSView(context: Context) -> Host { Host(theme: theme) }
    func updateNSView(_ view: Host, context: Context) { view.apply(theme) }

    final class Host: NSView {
        private let backdrop = NSHostingView(rootView: PreviewBackdrop())
        private let surface: GlassSurfaceView
        private var icons: [CALayer] = []
        private var theme: GlassTheme

        init(theme: GlassTheme) {
            self.theme = theme
            surface = GlassSurfaceView(theme: theme, backdrop: .withinWindow)
            super.init(frame: .zero)
            wantsLayer = true
            addSubview(backdrop)
            addSubview(surface)
            for name in ["safari", "envelope.fill", "music.note", "terminal", "folder.fill"] {
                let layer = CALayer()
                layer.contentsGravity = .resizeAspect
                layer.contents = TileImages.shared.symbol(name, fill: 0.62, color: .white, pixels: 96)
                surface.layer?.addSublayer(layer)
                icons.append(layer)
            }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func apply(_ newTheme: GlassTheme) {
            theme = newTheme
            surface.setTheme(newTheme)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            backdrop.frame = bounds
            surface.frame = bounds
            let tile: CGFloat = 46, gap: CGFloat = 12
            let padding = CGFloat(theme.padding)
            let width = tile * 5 + gap * 4 + padding * 2
            let height = tile + padding * 2
            let plate = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
            surface.plateFrame = plate
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, layer) in icons.enumerated() {
                layer.frame = CGRect(x: plate.minX + padding + CGFloat(index) * (tile + gap), y: plate.minY + padding, width: tile, height: tile)
            }
            CATransaction.commit()
        }

        override func mouseMoved(with event: NSEvent) { surface.setLight(at: convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { surface.setLight(at: nil) }
    }
}

/// Whether this Mac can provide Apple's own Liquid Glass. Checked at runtime so
/// the choice simply doesn't appear on macOS 14 or 15.
enum SystemGlassAvailability {
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var isMacOS27: Bool {
        if #available(macOS 27.0, *) { return true }
        return false
    }
}
