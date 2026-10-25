import AppKit
import SteamwatchCore

/// Draws the status-item image: a tag glyph plus the number of wishlist games on sale, and/or a
/// controller glyph plus hours played this week. Monochrome renders as a template image.
@MainActor
enum MenuBarIconRenderer {
    static let height: CGFloat = 18
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    nonisolated private static let glyphWidth: CGFloat = 14

    private enum Run {
        case glyph(String, NSColor)
        case text(String, NSFont, NSColor)
        case gap(CGFloat)

        var width: CGFloat {
            switch self {
            case .glyph: return glyphWidth
            case .text(let s, let f, _): return ceil((s as NSString).size(withAttributes: [.font: f]).width)
            case .gap(let g): return g
            }
        }
    }

    static func render(store: Store) -> NSImage {
        let d = UserDefaults.standard
        let mono = d.bool(forKey: SettingsKey.monochrome)
        let mode = MenuBarMode.current
        let text: NSColor = mono ? .black : .labelColor
        let hot = !store.deals.filter(\.meetsTarget).isEmpty

        var runs: [Run] = []
        func group(_ r: [Run]) {
            if !runs.isEmpty { runs.append(.gap(8)) }
            runs += r
        }
        // Nothing on sale: just the tag, no "0".
        if store.hasData, !store.deals.isEmpty, mode == .sales || mode == .both {
            let glyph: NSColor = mono ? .black : hot ? Theme.highlight : .labelColor
            group([.glyph("tag.fill", glyph), .gap(3), .text("\(store.deals.count)", font, text)])
        }
        if store.hasData, mode == .playtime || mode == .both {
            let minutes = store.weekMinutes > 0 ? store.weekMinutes : store.twoWeekMinutes
            group([.glyph("gamecontroller.fill", mono ? .black : .labelColor), .gap(3), .text(Format.hours(minutes), font, text)])
        }

        guard !runs.isEmpty else {
            let name = store.lastError != nil && !store.hasData ? "exclamationmark.triangle" : "tag.fill"
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "Steamwatch")!
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))!
            img.isTemplate = true
            return img
        }

        let total = runs.reduce(0) { $0 + $1.width }
        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            let mid = height / 2
            for run in runs {
                switch run {
                case .glyph(let name, let color):
                    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold).applying(.init(paletteColors: [color]))
                    if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                        let s = symbol.size
                        symbol.draw(in: NSRect(x: x + (glyphWidth - s.width) / 2, y: mid - s.height / 2, width: s.width, height: s.height))
                    }
                case .text(let s, let f, let color):
                    let size = (s as NSString).size(withAttributes: [.font: f])
                    (s as NSString).draw(at: NSPoint(x: x, y: mid - size.height / 2), withAttributes: [.font: f, .foregroundColor: color])
                case .gap: break
                }
                x += run.width
            }
            return true
        }
        image.isTemplate = mono
        return image
    }
}
