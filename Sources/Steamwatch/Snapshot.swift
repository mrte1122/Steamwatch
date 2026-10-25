import AppKit
import SwiftUI

/// `Steamwatch --snapshot <dir> [--demo]`: render the popover and the menu-bar item to PNGs
/// without touching the real status bar. Used for README screenshots and visual checks.
@MainActor
enum Snapshot {
    static func run(outDir: String) -> Never {
        _ = NSApplication.shared
        let store = Store()
        let dir = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            if Demo.isActive { store.loadDemo() } else { await store.refresh(force: true) }
            let d = UserDefaults.standard
            let savedMode = d.object(forKey: SettingsKey.menuBarMode), savedMono = d.object(forKey: SettingsKey.monochrome)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for (name, mode, mono) in [("sales", MenuBarMode.sales, false), ("both", .both, false), ("mono", .sales, true)] {
                    d.set(mode.rawValue, forKey: SettingsKey.menuBarMode)
                    d.set(mono, forKey: SettingsKey.monochrome)
                    write(MenuBarIconRenderer.render(store: store), appearance: appearance, scale: 3,
                          to: dir.appendingPathComponent("menubar-\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                }
            }
            d.set(savedMode, forKey: SettingsKey.menuBarMode); d.set(savedMono, forKey: SettingsKey.monochrome)

            let savedFilter = d.object(forKey: SettingsKey.dealFilter), savedSort = d.object(forKey: SettingsKey.dealSort)
            for (name, appearanceName, filter, sort) in [("light", NSAppearance.Name.aqua, "all", "best"), ("dark", .darkAqua, "all", "best"), ("targets-light", .aqua, "targets", "best"), ("rated-light", .aqua, "all", "rating"), ("sale-light", .aqua, "all", "best"), ("search-light", .aqua, "all", "best")] {
                d.set(filter, forKey: SettingsKey.dealFilter)
                d.set(sort, forKey: SettingsKey.dealSort)
                if name == "sale-light" { store.previewSaleEvent() } else { store.clearPreviewSaleEvent() }
                let view = PopoverView(store: store, updater: Updater(), openSettings: {}, previewSearch: name == "search-light" ? "er" : nil)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearanceName)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = host.appearance
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 500_000_000)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("popover-\(name).png"))
                }
            }
            d.set(savedFilter, forKey: SettingsKey.dealFilter)
            d.set(savedSort, forKey: SettingsKey.dealSort)
            print("Snapshots written to \(dir.path)")
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func write(_ image: NSImage, appearance: NSAppearance.Name, scale: CGFloat, to url: URL) {
        let size = NSSize(width: image.size.width + 12, height: max(image.size.height, 22))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            (appearance == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            let r = NSRect(x: 6, y: (size.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
            if image.isTemplate {
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    NSColor.labelColor.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: r)
            } else {
                image.draw(in: r)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
