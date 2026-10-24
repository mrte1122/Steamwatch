import Combine
import Foundation
import SteamwatchCore

/// Owns the refresh loop, the on-disk files and everything the popover shows.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var deals: [Deal] = []
    @Published private(set) var wishlistCount = 0
    @Published private(set) var recentGames: [RecentGame] = []
    @Published private(set) var playtime = PlaytimeLog()
    @Published private(set) var me: PlayerSummary?
    @Published private(set) var friendsOnline: [PlayerSummary] = []
    @Published private(set) var targets = Targets()
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    /// Problems with the keyed calls (playtime, friends) don't hide the deals, so they get their own line.
    @Published private(set) var playerError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var now = Date()

    let notifier = Notifier()
    private var history = PriceHistory()
    private var timer: Timer?
    private var clock: Timer?
    private var armed = false
    private var task: Task<Void, Never>?

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Steamwatch", isDirectory: true)
    }()
    private let cacheFile = JSONFile<CachedState>(url: directory.appendingPathComponent("cache.json"))
    private let historyFile = JSONFile<PriceHistory>(url: directory.appendingPathComponent("price-history.json"))
    private let playtimeFile = JSONFile<PlaytimeLog>(url: directory.appendingPathComponent("playtime.json"))
    private let targetsFile = JSONFile<Targets>(url: directory.appendingPathComponent("targets.json"))

    var steamID: String { UserDefaults.standard.string(forKey: SettingsKey.steamID) ?? "" }
    var apiKey: String? { Keychain.load(.apiKey) }
    var needsSetup: Bool { steamID.isEmpty && !Demo.isActive }
    var hasAPIKey: Bool { Demo.isActive || !(apiKey ?? "").isEmpty }
    var hasData: Bool { lastUpdated != nil }
    var weekMinutes: Int { playtime.weekMinutes(now: now) }
    var twoWeekMinutes: Int { recentGames.reduce(0) { $0 + $1.minutesTwoWeeks } }

    func client() -> SteamClient {
        SteamClient(apiKey: apiKey, countryCode: UserDefaults.standard.string(forKey: SettingsKey.countryCode) ?? "US")
    }

    // MARK: Lifecycle

    func start() {
        if Demo.isActive { loadDemo(); return }
        history = historyFile.load() ?? PriceHistory()
        playtime = playtimeFile.load() ?? PlaytimeLog()
        targets = targetsFile.load() ?? Targets()
        if let cached = cacheFile.load() { apply(cached) }
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        scheduleTimer()
        Task { await refresh() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleTimer() }
        }
    }

    private var scheduledInterval: TimeInterval = 0
    private func scheduleTimer() {
        let interval = max(300, min(21_600, UserDefaults.standard.double(forKey: SettingsKey.refreshInterval)))
        guard interval != scheduledInterval else { return }
        scheduledInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// Re-read the files after a profile change so another account's lows don't bleed over.
    func resetForNewProfile() {
        history = PriceHistory()
        playtime = PlaytimeLog()
        deals = []; recentGames = []; me = nil; friendsOnline = []; wishlistCount = 0
        lastUpdated = nil; lastError = nil; playerError = nil
        try? historyFile.save(history)
        try? playtimeFile.save(playtime)
        UserDefaults.standard.set([String](), forKey: SettingsKey.sentAlerts)
        armed = false
        Task { await refresh(force: true) }
    }

    // MARK: Refresh

    func refresh(force: Bool = false) async {
        guard !Demo.isActive, !needsSetup else { return }
        if let task, !force { await task.value; return }
        task?.cancel()
        let t = Task { await performRefresh() }
        task = t
        await t.value
        task = nil
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false; now = Date() }
        let client = client()
        let id = steamID
        do {
            let wishlist = try await client.wishlist(steamID: id)
            let items = wishlist.isEmpty ? [] : try await client.storeItems(wishlist.map(\.appID))
            let fresh = DealEngine.deals(wishlist: wishlist, items: items, history: history, targets: targets.byAppID)
            let at = Date()
            for item in items { history.observe(item, at: at) }
            history.prune(keeping: Set(wishlist.map(\.appID)), now: at)
            try? historyFile.save(history)
            deals = fresh
            wishlistCount = wishlist.count
            lastUpdated = at
            lastError = wishlist.isEmpty ? "Wishlist is empty or private. Steam → Privacy Settings → Game details: Public." : nil
            notify(fresh)
        } catch {
            lastError = error.localizedDescription
        }

        if hasAPIKey {
            do {
                let games = try await client.recentlyPlayed(steamID: id)
                recentGames = games
                playtime.record(games, at: Date())
                try? playtimeFile.save(playtime)
                let summaries = try await client.playerSummaries([id])
                me = summaries.first
                if UserDefaults.standard.bool(forKey: SettingsKey.showFriends) {
                    let ids = try await client.friendIDs(steamID: id)
                    let online = ids.isEmpty ? [] : try await client.playerSummaries(ids).filter(\.isOnline)
                    // In-game friends first, then alphabetical.
                    friendsOnline = online.sorted { a, b in
                        if (a.currentGame == nil) != (b.currentGame == nil) { return a.currentGame != nil }
                        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    }
                } else {
                    friendsOnline = []
                }
                playerError = nil
            } catch {
                playerError = error.localizedDescription
            }
        } else {
            playerError = nil
        }
        armed = true
        if lastUpdated != nil {
            try? cacheFile.save(CachedState(fetchedAt: lastUpdated ?? Date(), wishlist: [], items: [], recentGames: recentGames,
                                            me: me, friendsOnline: friendsOnline))
        }
    }

    private func notify(_ deals: [Deal]) {
        let d = UserDefaults.standard
        var sent = Set(d.stringArray(forKey: SettingsKey.sentAlerts) ?? [])
        let policy = DealEngine.Policy(target: d.bool(forKey: SettingsKey.notifyTarget), newLow: d.bool(forKey: SettingsKey.notifyNewLow),
                                       firstSale: d.bool(forKey: SettingsKey.notifyFirstSale), anySale: d.bool(forKey: SettingsKey.notifyAnySale))
        let alerts = d.bool(forKey: SettingsKey.notificationsEnabled)
            ? DealEngine.alerts(for: deals, alreadySent: sent, policy: policy, armed: armed) : []
        for a in alerts { notifier.post(a) }
        // Everything on sale right now counts as announced, so a sale is never reported twice.
        sent.formUnion(DealEngine.keys(for: deals))
        d.set(Array(sent.sorted().suffix(1000)), forKey: SettingsKey.sentAlerts)
    }

    private func apply(_ cached: CachedState) {
        recentGames = cached.recentGames
        me = cached.me
        friendsOnline = cached.friendsOnline
    }

    // MARK: Targets

    func setTarget(_ cents: Int?, for appID: AppID) {
        targets[appID] = cents
        try? targetsFile.save(targets)
        // Re-rank without a network round trip.
        deals = DealEngine.deals(wishlist: deals.map { WishlistEntry(appID: $0.item.appID, priority: 0, added: .distantPast) },
                                 items: deals.map(\.item), history: historyWithoutCurrent(), targets: targets.byAppID)
    }

    /// `deals` were judged against history *before* the latest reading; rebuilding them from the
    /// stored lows would mark every deal "equal to the low". Reconstruct the earlier view instead.
    private func historyWithoutCurrent() -> PriceHistory {
        var h = PriceHistory()
        for d in deals {
            guard let low = d.lowestSeenCents else { continue }
            h.records[String(d.item.appID)] = .init(currency: d.price.currency, lowestCents: low, lowestAt: .distantPast, lastCents: low,
                                                    lastSeen: .distantPast, firstSeen: .distantPast, seenOnSale: !d.isFirstSale)
        }
        return h
    }

    // MARK: Demo

    func loadDemo() {
        targets = DemoData.targets
        deals = DealEngine.deals(wishlist: DemoData.wishlist, items: DemoData.items, history: DemoData.history, targets: targets.byAppID)
        wishlistCount = 41
        recentGames = DemoData.recentGames
        playtime = DemoData.playtime
        me = DemoData.me
        friendsOnline = DemoData.friendsOnline
        lastUpdated = Date().addingTimeInterval(-12 * 60)
        lastError = nil
    }

    func diagnosticsText() -> String {
        var lines = ["Steamwatch \(SteamClient.version)", "steamID: \(steamID.isEmpty ? "(not set)" : steamID)", "api key: \(hasAPIKey ? "set" : "none")"]
        if let u = lastUpdated { lines.append("updated: \(u)") }
        lines.append("wishlist: \(wishlistCount) · on sale: \(deals.count)")
        for d in deals { lines.append("  \(d.item.name): \(Format.price(d.price.finalCents, currency: d.price.currency)) −\(d.price.discountPercent)%\(d.meetsTarget ? " TARGET" : "")\(d.isNewLow ? " LOW" : "")\(d.isFirstSale ? " FIRST" : "")") }
        lines.append("played 2 wk: \(Format.hours(twoWeekMinutes)) · friends online: \(friendsOnline.count)")
        if let e = lastError { lines.append("error: \(e)") }
        if let e = playerError { lines.append("player error: \(e)") }
        return lines.joined(separator: "\n")
    }
}
