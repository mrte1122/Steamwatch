import AppKit
import VaporwatchCore

@main
enum Entry {
    @MainActor
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered, so CLI modes print immediately even when piped
        SettingsKey.registerDefaults()
        Keychain.migrateLegacy()
        SteamClient.version = Updater.currentVersion
        let args = CommandLine.arguments

        if args.contains("--selftest") { exit(SelfTest.run()) }
        if args.contains("--once") { runOnce() }
        if let i = args.firstIndex(of: "--search"), i + 1 < args.count { runSearch(args[i + 1]) }
        if args.contains("--suggest") { runSuggest() }
        if args.contains("--check-key") { runCheckKey() }
        if args.contains("--migrate-keychain") { print(Keychain.migrateLegacy()); exit(0) }
        if args.contains("--check-update") || args.contains("--update") {
            runUpdate(install: args.contains("--update"))
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { Snapshot.run(outDir: args[i + 1]) }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar only, like LSUIElement
        app.run()
    }

    /// `--once [--demo]`: fetch once and print a summary (never the key).
    @MainActor
    private static func runOnce() -> Never {
        let store = Store()
        Task { @MainActor in
            if Demo.isActive { store.loadDemo() } else { await store.refresh(force: true) }
            print(store.diagnosticsText())
            if store.needsSetup { print("not set up: defaults write io.github.mrte1122.Steamwatch steamID <SteamID64>") }
            exit(store.lastError == nil && !store.needsSetup ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }
}

extension Entry {
    /// `--check-key`: try each call that needs the Web API key and print its HTTP status. The key
    /// itself is never printed.
    @MainActor
    static func runCheckKey() -> Never {
        let store = Store()
        Task { @MainActor in
            guard let key = store.apiKey, !key.isEmpty else { print("no API key saved"); exit(1) }
            let id = store.steamID
            print("key: \(key.count) characters, \(key.allSatisfy(\.isHexDigit) ? "hex" : "NOT hex (expected 32 hex characters)")")
            let calls: [(String, [(String, String)])] = [
                ("IPlayerService/GetRecentlyPlayedGames/v1/", [("steamid", id)]),
                ("ISteamUser/GetPlayerSummaries/v2/", [("steamids", id)]),
                ("ISteamUser/GetFriendList/v1/", [("steamid", id), ("relationship", "friend")]),
                ("IPlayerService/GetOwnedGames/v1/", [("steamid", id), ("include_played_free_games", "1")]),
            ]
            for (path, query) in calls {
                var comps = URLComponents(url: SteamClient.api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
                comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } + [URLQueryItem(name: "key", value: key)]
                let (data, status) = (try? await URLSessionTransport().get(comps.url!)) ?? (Data(), -1)
                let body = String(decoding: data.prefix(80), as: UTF8.self).replacingOccurrences(of: key, with: "<key>")
                print("\(status)\t\(path)\t\(status == 200 ? "\(data.count) bytes" : body)")
            }
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// `--suggest`: refresh, then fetch and print suggestions (ignores the twice-a-day limit).
    @MainActor
    static func runSuggest() -> Never {
        let store = Store()
        Task { @MainActor in
            if Demo.isActive { store.loadDemo() } else {
                await store.refresh(force: true)
                await store.refreshSuggestions(force: true)
            }
            for s in store.visibleSuggestions {
                let price = s.item.price.map { "\(Format.price($0.finalCents, currency: $0.currency)) −\($0.discountPercent)%" } ?? ""
                print("\(s.item.name)\t\(price)\t\(s.item.reviews.map { "\($0.percentPositive)%" } ?? "")\t\(store.tagNames(for: s).joined(separator: ", "))")
            }
            print("\(store.visibleSuggestions.count) suggestion(s)" + (store.suggestionNote.map { " — \($0)" } ?? ""))
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// `--search <term>`: the store search behind the popover's + panel, printed.
    @MainActor
    static func runSearch(_ term: String) -> Never {
        Task { @MainActor in
            do {
                let found = try await Store().client().search(term)
                for item in found.prefix(10) {
                    let price = item.price.map { Format.price($0.finalCents, currency: $0.currency) + ($0.isOnSale ? " −\($0.discountPercent)%" : "") } ?? "no price"
                    print("\(item.appID)\t\(item.name)\t\(price)")
                }
                print("\(found.count) result(s)")
                exit(0)
            } catch {
                print("error:", error.localizedDescription)
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    /// `--check-update` reports the latest release; `--update` also installs it (no relaunch).
    @MainActor
    static func runUpdate(install: Bool) -> Never {
        _ = NSApplication.shared
        let updater = Updater()
        Task { @MainActor in
            print("installed:", Updater.currentVersion, "at", Bundle.main.bundleURL.path)
            print("install location:", Updater.installLocationProblem ?? "ok, updates can install here")
            await updater.check(userInitiated: true)
            switch updater.state {
            case .available(let release):
                print("available:", release.version)
                if install {
                    await updater.install(release, relaunch: false)
                    if case .failed(let message) = updater.state { print("error:", message); exit(1) }
                    let plist = NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))
                    print("installed now:", plist?["CFBundleShortVersionString"] as? String ?? "?")
                }
                exit(0)
            case .upToDate: print("up to date"); exit(0)
            case .noReleases: print("no releases published yet"); exit(0)
            case .failed(let message): print("error:", message); exit(1)
            default: exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}

/// Smoke checks that run inside the built .app in CI (the XCTest suite covers the core in depth).
enum SelfTest {
    @MainActor
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "ok   " : "FAIL ", what)
            if !ok { failures += 1 }
        }
        let deals = DealEngine.deals(wishlist: DemoData.wishlist, items: DemoData.items, history: DemoData.history, targets: DemoData.targets.byAppID)
        check(deals.count == 7, "demo data yields 7 deals")
        check(deals.first?.meetsTarget == true, "target hit ranks first")
        check(SteamProfileRef(parsing: "https://steamcommunity.com/profiles/76561197960287930") == .id64("76561197960287930"), "profile URL parses")
        check(Format.price(1199, currency: "USD") == "$11.99", "price formatting")
        let store = Store()
        store.loadDemo()
        let image = MenuBarIconRenderer.render(store: store)
        check(image.size.width > 14 && image.size.height == MenuBarIconRenderer.height, "menu bar image renders (\(Int(image.size.width))pt)")
        let burst = deals.map { DealAlert(kind: .newLow, deal: $0) }
        check(NotificationPlan.plan(burst, totalOnSale: deals.count, event: nil).digest?.alerts.count == 7, "a burst of alerts becomes one digest")
        check(Updater.isVersion("0.10.0", newerThan: "0.9.9") && !Updater.isVersion("0.1.0", newerThan: "0.1.0"), "version comparison")
        let payload = Data("vaporwatch".utf8)
        check((try? Updater.verify(payload, signature: Data("AAAA".utf8))) == nil, "updater rejects a bad signature")
        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        return failures == 0 ? 0 : 1
    }
}
