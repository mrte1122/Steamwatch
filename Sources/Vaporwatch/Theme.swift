import AppKit
import SwiftUI

enum Theme {
    /// Sale green for the tag glyph, target hits and the chart. Not a Valve mark, just a color.
    static let accent = NSColor(srgbRed: 0.18, green: 0.62, blue: 0.36, alpha: 1)
    static let highlight = NSColor.systemGreen

    /// Bright system colors are hard to read on a light background, so darken them there.
    static func readable(_ color: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? color
                : (color.blended(withFraction: 0.32, of: .black) ?? color)
        }
    }
}

extension Color {
    init(ns: NSColor) { self.init(nsColor: ns) }
}

/// Card surface: white with a hairline border in light mode, translucent grey in dark mode.
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return content
            .background(shape.fill(tint.map { AnyShapeStyle($0.opacity(scheme == .dark ? 0.22 : 0.14)) }
                                   ?? (scheme == .dark ? AnyShapeStyle(.quaternary.opacity(0.5))
                                                       : AnyShapeStyle(Color.white.opacity(0.9)))))
            .overlay(shape.strokeBorder(Color.black.opacity(scheme == .dark || tint != nil ? 0 : 0.07), lineWidth: 1))
    }
}

extension View {
    func card(tint: Color? = nil) -> some View { modifier(CardBackground(tint: tint)) }
}
