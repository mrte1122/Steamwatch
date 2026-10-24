# Windows port notes

The macOS app is two layers, and only the top one is Apple-specific.

## What already works on Windows

`Sources/SteamwatchCore` imports nothing but Foundation (plus `FoundationNetworking` on
non-Apple platforms, already guarded). With the Swift toolchain for Windows installed:

```powershell
swift build --target SteamwatchCore
swift test
```

`Package.swift` only declares the macOS executable target when evaluated on macOS, so the package
resolves cleanly elsewhere. The CI workflow runs the core tests on Linux for the same reason.

Everything below is in the core and needs no porting:

| Area | Type | Notes |
| --- | --- | --- |
| Steam HTTP calls | `SteamClient` | `HTTPTransport` protocol; `URLSessionTransport` works via FoundationNetworking, or supply a WinHTTP-based one |
| Profile input parsing | `SteamProfileRef` | URL / SteamID64 / vanity name |
| Which games are deals and in what order | `DealEngine.deals` | pure function |
| Which deals deserve a notification | `DealEngine.alerts` | pure function; platform posts them |
| Lowest-price memory | `PriceHistory` | `price-history.json` |
| Daily playtime from Steam's 2-week counter | `PlaytimeLog` | `playtime.json` |
| Target prices | `Targets` | `targets.json` |
| Last good reading | `CachedState` | `cache.json` |
| Price / hours / relative-time strings | `Format` | locale-aware via `NumberFormatter` |
| Sample data | `DemoData` | for screenshots and tests |
| Atomic JSON persistence | `JSONFile<T>` | ISO-8601 dates, sorted keys |

## What the Windows app has to provide

Mirror `Sources/Steamwatch` file by file:

| macOS file | Does | Windows equivalent |
| --- | --- | --- |
| `Store.swift` | refresh loop, owns the JSON files, calls `DealEngine`, hands alerts to the notifier | same logic; put the files under `%LOCALAPPDATA%\Steamwatch\` |
| `App.swift` | `NSStatusItem` + `NSPopover` | tray icon (`Shell_NotifyIcon` / WinUI 3 `TaskbarIcon`) + a flyout window |
| `MenuBarIcon.swift` | draws "tag + count" into the status item | tray icons are 16×16 and can't carry text well: draw the count into the icon bitmap, or show it in the tooltip and flyout |
| `PopoverView.swift`, `SettingsView.swift` | SwiftUI | WinUI 3 / WPF; the row model is `Deal`, `DayPlaytime`, `PlayerSummary` |
| `Keychain.swift` | API key storage | Windows Credential Manager (`CredWrite`) or DPAPI |
| `Notifier.swift` | `UNUserNotificationCenter`, opens the store page on click | toast notifications (`Windows.UI.Notifications`) with the store URL as the launch argument |
| `Settings.swift` | `UserDefaults` keys and defaults | registry or a `settings.json`; keep the key names so docs stay shared |
| `Entry.swift` | `--once`, `--demo`, `--selftest`, `--snapshot` | keep `--once` and `--demo` at least; they make debugging painless |

## Two ways to build it

1. **Swift all the way.** Swift on Windows is production-ready and the core compiles as-is. The
   UI layer would be Swift calling WinRT through [swift-winrt](https://github.com/thebrowsercompany/swift-winrt)
   (The Browser Company ships Arc for Windows this way). Highest reuse, steepest tooling curve.
2. **C# (WinUI 3) UI over a C# port of the core.** The core is ~700 lines of plain logic with
   tests, so a port is a day's work; the JSON file formats and Steam calls are documented above and
   in `README.md`. Lower reuse, but the easiest path to a polished tray app.

Either way, keep the file formats identical so a user can carry `price-history.json` between
machines, and keep `DealEngine`'s ranking rules (target → first sale → new low → by discount) and
alert dedup keys (`"<appid>-<finalCents>"`) the same so both apps behave alike.

## Steam specifics worth knowing

- `GetItems` returns prices as strings (`"final_price_in_cents": "2249"`); `IntOrString` in
  `SteamClient.swift` handles both shapes.
- A private wishlist and an empty one both come back as `{"response":{}}`.
- Store calls take a `country_code`; prices and currency follow it, and `PriceHistory` resets a
  game's record when its currency changes.
- Keyed calls answer 403 for a bad key and `{"response":{}}` for a private profile.
