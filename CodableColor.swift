import SwiftUI
import AppKit

/// SwiftUI's `Color` isn't `Codable`, so every persisted colour in Dawck is
/// stored as plain RGBA components and converted to/from `Color` at the edges.
struct CodableColor: Codable, Equatable, Hashable {
    var red: Double = 0.11
    var green: Double = 0.11
    var blue: Double = 0.13
    var alpha: Double = 1.0

    init(red: Double = 0.11, green: Double = 0.11, blue: Double = 0.13, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Hand-written so one malformed component falls back instead of failing
    /// the whole theme it belongs to.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        red = c.value(.red, 0.11)
        green = c.value(.green, 0.11)
        blue = c.value(.blue, 0.13)
        alpha = c.value(.alpha, 1.0)
    }

    private enum CodingKeys: String, CodingKey { case red, green, blue, alpha }

    /// `Color.resolve(in:)` flattens whatever the colour actually is — a
    /// picker result, a named asset, a dynamic system colour — down to
    /// concrete components. Resolving against a bare `EnvironmentValues()`
    /// captures a *dynamic* colour in its light-appearance form, which is the
    /// right trade here: these are user-picked tints that should stay exactly
    /// the shade that was picked rather than shifting with appearance.
    init(color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        red = Double(resolved.red)
        green = Double(resolved.green)
        blue = Double(resolved.blue)
        alpha = Double(resolved.opacity)
    }

    /// `RRGGBB` or `RRGGBBAA`, with or without a leading `#`. Anything else
    /// yields mid-grey rather than crashing: palette data is parsed from
    /// strings, and strings can be wrong.
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else {
            self.init(red: 0.5, green: 0.5, blue: 0.5)
            return
        }
        if text.count == 6 {
            self.init(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        } else {
            self.init(
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                alpha: Double(value & 0xFF) / 255
            )
        }
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    var nsColor: NSColor { NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha)) }

    var cgColor: CGColor { CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha)) }

    /// Perceived brightness (Rec. 601), the weighting Goorgle's text-colour
    /// rule was tuned against.
    var luminance: Double { 0.299 * red + 0.587 * green + 0.114 * blue }

    func with(alpha newAlpha: Double) -> CodableColor {
        CodableColor(red: red, green: green, blue: blue, alpha: newAlpha)
    }

    /// Rotates the hue by a 0...1 fraction of the wheel.
    func hueRotated(by fraction: Double) -> CodableColor {
        guard let hsb = nsColor.usingColorSpace(.deviceRGB) else { return self }
        let hue = (hsb.hueComponent + CGFloat(fraction)).truncatingRemainder(dividingBy: 1)
        guard let rotated = NSColor(hue: hue, saturation: hsb.saturationComponent,
                                    brightness: hsb.brightnessComponent, alpha: hsb.alphaComponent)
            .usingColorSpace(.sRGB) else { return self }
        return CodableColor(red: Double(rotated.redComponent), green: Double(rotated.greenComponent),
                            blue: Double(rotated.blueComponent), alpha: alpha)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to `fallback` when the key is missing *or*
    /// holds the wrong type. Synthesized `Decodable` throws in both cases, which
    /// would discard a whole saved theme or dock over one bad field.
    func value<T: Decodable>(_ key: Key, _ fallback: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback()
    }
}
