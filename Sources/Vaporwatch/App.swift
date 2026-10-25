import AppKit
import Combine
import VaporwatchCore
import SwiftUI

/// NSStatusItem + NSPopover (rather than MenuBarExtra, which forces template rendering on the
/// label and would lose the green target-hit tint).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let updater = Updater()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Updater.renameLegacyBundleIfNeeded() { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageOnly

        let host = NSHostingController(rootView: PopoverView(store: store, updater: updater) { [weak self] in self?.openSettings() })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon(); self?.applyTheme() }
            .store(in: &cancellables)

        applyTheme()
        if UserDefaults.standard.bool(forKey: SettingsKey.notificationsEnabled) {
            store.notifier.requestAuthorization()
        }
        updateIcon()
        store.start()
        updater.notifier = store.notifier
        updater.start()
        if store.needsSetup { openSettings() }
    }

    private var appliedTheme: ThemeChoice?

    /// Only on a real change: re-setting the appearance on every UserDefaults write (which
    /// happens per keystroke in Settings) resets the key window's focus mid-typing.
    private func applyTheme() {
        let choice = ThemeChoice.current
        guard choice != appliedTheme || settingsWindow?.appearance != choice.appearance else { return }
        appliedTheme = choice
        popover.appearance = choice.appearance
        settingsWindow?.appearance = choice.appearance
    }

    private func updateIcon() {
        statusItem.button?.image = MenuBarIconRenderer.render(store: store)
        statusItem.button?.toolTip = tooltip
    }

    private var tooltip: String {
        guard store.hasData else { return "Vaporwatch — wishlist sale watcher" }
        var lines = ["\(store.deals.count) of \(store.wishlistCount) wishlist games on sale"]
        for d in store.deals.prefix(5) {
            lines.append("\(d.item.name): \(Format.price(d.price.finalCents, currency: d.price.currency)) (−\(d.price.discountPercent)%)")
        }
        return lines.joined(separator: "\n")
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Activate first: as a menu-bar-only app Vaporwatch is otherwise never the active app,
            // and the popover's controls then draw in macOS's dimmed "inactive window" style.
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store, updater: updater)))
            w.title = "Vaporwatch Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
            applyTheme()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
