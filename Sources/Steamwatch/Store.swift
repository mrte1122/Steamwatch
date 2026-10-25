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
    @Published private(set) var hidden = HiddenGames()
    /// Every wishlisted game the store knows about, for the Targets and Hidden lists in Settings.
    @Published private(set) var items: [AppID: StoreItem] = [:]
    private var wishlist: [WishlistEntry] = []
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
    private let hiddenFile = JSONFile<HiddenGames>(url: directory.appendingPathComponent("hidden.json"))
    private let saleEventFile = JSONFile<SaleEvent>(url: directory.appendingPathComponent("sale-event.json"))

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
        hidden = hiddenFile.load() ?? HiddenGames()
        saleEvent = saleEventFile.load()
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
        hidden = HiddenGames()
        saleEvent = nil
        try? FileManager.default.removeItem(at: saleEventFile.url)
        deals = []; recentGames = []; me = nil; friendsOnline = []; wishlistCount = 0; items = [:]; wishlist = []
        lastUpdated = nil; lastError = nil; playerError = nil
        try? historyFile.save(history)
        try? playtimeFile.save(playtime)
        try? hiddenFile.save(hidden)
        UserDefaults.standard.set([String](), forKey: SettingsKey.sentAlerts)
        armed = false
        Task { await refresh(force: true) }
    }

    // MARK: Refresh

    func refresh(force: Bool = false) async {
        guard !Demo.isActive, !needsSetup else { return }
        if let task, !force { await task.value; return }
        if force { userForced = true }
        task?.cancel()
        let t = Task { await performRefresh() }
        task = t
        await t.value
        task = nil
    }

    /// A failed or partial refresh never blanks the popover: the last good deals stay, the banner
    /// says what went wrong, and a retry is scheduled with growing delays. Prices for batches that
    /// failed are carried over from the previous reading and counted as stale.
    private func performRefresh() async {
        if let until = rateLimitedUntil, until > Date(), !userForced {
            lastError = "Steam asked us to slow down; next check \(Format.relative(until, now: Date()).replacingOccurrences(of: "ago", with: "from now"))."
            return
        }
        userForced = false
        isRefreshing = true
        defer { isRefreshing = false; now = Date() }
        let client = client()
        let id = steamID
        var failed: SteamError?

        do {
            let wishlist = try await client.wishlist(steamID: id)
            let ids = Set(wishlist.map(\.appID))
            let fetched = wishlist.isEmpty ? SteamClient.StoreResult(items: [], missing: [], error: nil)
                                           : await client.storeItems(partial: wishlist.map(\.appID))
            // Fill gaps from the last reading so a game doesn't vanish because its batch failed.
            let carried = fetched.missing.compactMap { items[$0] }
            let merged = fetched.items + carried
            staleCount = carried.count
            failed = fetched.error

            hidden.prune(keeping: ids)
            try? hiddenFile.save(hidden)
            let fresh = DealEngine.deals(wishlist: wishlist, items: merged, history: history, targets: targets.byAppID, hidden: hidden.appIDs)
            let at = Date()
            for item in fetched.items { history.observe(item, at: at) }
            history.prune(keeping: ids, now: at)
            try? historyFile.save(history)
            let previousIDs = Set(deals.map(\.id))
            deals = fresh
            updateSaleEvent(previousIDs: previousIDs, wishlistCount: wishlist.count)
            self.wishlist = wishlist
            items = Dictionary(merged.map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })
            wishlistCount = wishlist.count
            lastUpdated = at
            if wishlist.isEmpty {
                lastError = "Wishlist is empty or private. Steam → Privacy Settings → Game details: Public."
            } else if let e = fetched.error {
                let unknown = fetched.missing.count - carried.count
                lastError = "Prices for \(fetched.missing.count) games didn't load (\(e.localizedDescription.lowercased().dropLast()))"
                    + (unknown > 0 ? "; \(unknown) have no earlier price and are left out." : "; showing their last known prices.")
            } else {
                lastError = nil
            }
            notify(fresh)
        } catch {
            failed = error as? SteamError ?? .transport(error.localizedDescription)
            lastError = hasData ? "\(failed!.localizedDescription) Showing the last reading from \(Format.relative(lastUpdated ?? Date(), now: Date()))."
                                : failed!.localizedDescription
        }

        if hasAPIKey {
            await refreshPlayer(client: client, id: id)
        } else {
            playerError = nil
        }
        armed = true
        if let at = lastUpdated {
            try? cacheFile.save(CachedState(fetchedAt: at, wishlist: wishlist, items: Array(items.values), recentGames: recentGames,
                                            me: me, friendsOnline: friendsOnline))
        }
        scheduleRetry(after: failed)
    }

    /// Keyed calls are independent of the store: a failure here only affects the playtime and
    /// friends sections, and each part keeps whatever it last had.
    private func refreshPlayer(client: SteamClient, id: String) async {
        var errors: [String] = []
        do {
            let games = try await client.recentlyPlayed(steamID: id)
            recentGames = games
            playtime.record(games, at: Date())
            try? playtimeFile.save(playtime)
        } catch {
            errors.append(error.localizedDescription)
            if (error as? SteamError) == .badAPIKey { playerError = error.localizedDescription; return }
        }
        do {
            me = try await client.playerSummaries([id]).first
        } catch {
            errors.append(error.localizedDescription)
        }
        if UserDefaults.standard.bool(forKey: SettingsKey.showFriends) {
            do {
                let ids = try await client.friendIDs(steamID: id)
                let online = ids.isEmpty ? [] : try await client.playerSummaries(ids).filter(\.isOnline)
                // In-game friends first, then alphabetical.
                friendsOnline = online.sorted { a, b in
                    if (a.currentGame == nil) != (b.currentGame == nil) { return a.currentGame != nil }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        } else {
            friendsOnline = []
        }
        playerError = errors.first
        if errors.contains(where: { $0 == SteamError.rateLimited.localizedDescription }) { noteRateLimit() }
    }

    // MARK: Backoff

    /// Set by the Refresh button so a cooldown can be overridden on purpose.
    private var userForced = false
    @Published private(set) var rateLimitedUntil: Date?
    /// Games whose prices came from the previous reading because their batch failed.
    @Published private(set) var staleCount = 0
    /// A storewide sale inferred from a jump in discounted wishlist games; drives the banner and digest.
    @Published private(set) var saleEvent: SaleEvent?
    private var retryTimer: Timer?
    private var consecutiveFailures = 0

    private func noteRateLimit() {
        // 5 min, then doubling to 40 min, so a long ban isn't poked every few minutes.
        let minutes = min(40.0, 5.0 * pow(2.0, Double(consecutiveFailures)))
        rateLimitedUntil = Date().addingTimeInterval(minutes * 60)
    }

    private func scheduleRetry(after error: SteamError?) {
        retryTimer?.invalidate()
        guard let error else {
            consecutiveFailures = 0
            rateLimitedUntil = nil
            return
        }
        if error == .rateLimited { noteRateLimit() }
        consecutiveFailures += 1
        // 2, 4, 8, 16, then 30 minutes; never sooner than the rate-limit cooldown.
        var delay = min(30.0, 2.0 * pow(2.0, Double(consecutiveFailures - 1))) * 60
        if let until = rateLimitedUntil { delay = max(delay, until.timeIntervalSinceNow + 5) }
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func updateSaleEvent(previousIDs: Set<AppID>, wishlistCount: Int) {
        let next = SaleEvent.evaluate(saleEvent, previousIDs: previousIDs, deals: deals, wishlistCount: wishlistCount)
        guard next != saleEvent else { return }
        saleEvent = next
        if let next { try? saleEventFile.save(next) } else { try? FileManager.default.removeItem(at: saleEventFile.url) }
    }

    /// For screenshots: pretend a sale started with only two games discounted beforehand.
    func previewSaleEvent() {
        saleEvent = SaleEvent(started: Date(), baselineCount: 2, ends: Date().addingTimeInterval(3 * 86_400 + 3600))
    }

    private func notify(_ deals: [Deal]) {
        let d = UserDefaults.standard
        var sent = Set(d.stringArray(forKey: SettingsKey.sentAlerts) ?? [])
        let policy = DealEngine.Policy(target: d.bool(forKey: SettingsKey.notifyTarget), newLow: d.bool(forKey: SettingsKey.notifyNewLow),
                                       firstSale: d.bool(forKey: SettingsKey.notifyFirstSale), anySale: d.bool(forKey: SettingsKey.notifyAnySale))
        let alerts = d.bool(forKey: SettingsKey.notificationsEnabled)
            ? DealEngine.alerts(for: deals, alreadySent: sent, policy: policy, armed: armed) : []
        // Target hits post on their own; a burst of other alerts, or any during a big sale, becomes one digest.
        let plan = NotificationPlan.plan(alerts, totalOnSale: deals.count, event: saleEvent)
        for a in plan.individual { notifier.post(a) }
        if let digest = plan.digest {
            notifier.post(title: digest.title, body: digest.body, url: Links.wishlist, id: "digest-\(Int(Date().timeIntervalSince1970))")
        }
        // Everything on sale right now counts as announced, so a sale is never reported twice.
        sent.formUnion(DealEngine.keys(for: deals))
        d.set(Array(sent.sorted().suffix(1000)), forKey: SettingsKey.sentAlerts)
    }

    /// The last reading, shown until the first refresh lands. Lows are judged against the history
    /// that already includes this reading, so nothing shows as "new low" until then.
    private func apply(_ cached: CachedState) {
        recentGames = cached.recentGames
        me = cached.me
        friendsOnline = cached.friendsOnline
        wishlist = cached.wishlist
        items = Dictionary(cached.items.map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })
        if !cached.wishlist.isEmpty {
            wishlistCount = cached.wishlist.count
            deals = DealEngine.deals(wishlist: cached.wishlist, items: cached.items, history: history, targets: targets.byAppID, hidden: hidden.appIDs)
            lastUpdated = cached.fetchedAt
        }
    }

    // MARK: Targets and hiding

    func setTarget(_ cents: Int?, for appID: AppID) {
        targets[appID] = cents
        try? targetsFile.save(targets)
        rerank()
    }

    func hide(_ appID: AppID) {
        if let d = deals.first(where: { $0.id == appID }) { hiddenDeals.append(d) }
        hidden.hide(appID)
        try? hiddenFile.save(hidden)
        rerank()
    }

    func unhide(_ appID: AppID) {
        hidden.unhide(appID)
        try? hiddenFile.save(hidden)
        rerank()
    }

    func unhideAll() {
        hidden = HiddenGames()
        try? hiddenFile.save(hidden)
        rerank()
    }

    /// Re-run the engine without a network round trip, over the last reading's wishlist and items.
    private func rerank() {
        if Demo.isActive {
            deals = DealEngine.deals(wishlist: DemoData.wishlist, items: DemoData.items, history: DemoData.history,
                                     targets: targets.byAppID, hidden: hidden.appIDs)
            return
        }
        guard !wishlist.isEmpty else { return }
        deals = DealEngine.deals(wishlist: wishlist, items: Array(items.values), history: historyWithoutCurrent(), targets: targets.byAppID,
                                 hidden: hidden.appIDs)
    }

    /// `deals` were judged against history *before* the latest reading; rebuilding them from the
    /// stored lows would mark every deal "equal to the low". Reconstruct the earlier view for the
    /// deals we have (hidden ones included, so unhiding restores their flags) and fall back to the
    /// stored history for anything else.
    private func historyWithoutCurrent() -> PriceHistory {
        var h = history
        for d in deals + hiddenDeals {
            if let low = d.lowestSeenCents {
                h.records[String(d.item.appID)] = .init(currency: d.price.currency, lowestCents: low, lowestAt: .distantPast, lastCents: low,
                                                        lastSeen: .distantPast, firstSeen: .distantPast, seenOnSale: !d.isFirstSale)
            } else {
                h.records[String(d.item.appID)] = nil
            }
        }
        return h
    }

    /// Deals hidden this session keep their pre-reading flags here so unhiding restores them exactly.
    private var hiddenDeals: [Deal] = []

    // MARK: Demo

    func loadDemo() {
        targets = DemoData.targets
        items = Dictionary(DemoData.items.map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })
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
        lines.append("wishlist: \(wishlistCount) · on sale: \(deals.count) · hidden: \(hidden.count) · targets: \(targets.cents.count)"
                     + (staleCount > 0 ? " · stale prices: \(staleCount)" : ""))
        if let until = rateLimitedUntil, until > Date() { lines.append("rate limited until: \(until)") }
        if let e = saleEvent { lines.append("sale event: since \(e.started), +\(e.extra(deals)) deals" + (e.ends.map { ", most end \($0)" } ?? "")) }
        for d in deals { lines.append("  \(d.item.name): \(Format.price(d.price.finalCents, currency: d.price.currency)) −\(d.price.discountPercent)%\(d.meetsTarget ? " TARGET" : "")\(d.isNewLow ? " LOW" : "")\(d.isFirstSale ? " FIRST" : "")") }
        lines.append("played 2 wk: \(Format.hours(twoWeekMinutes)) · friends online: \(friendsOnline.count)")
        if let e = lastError { lines.append("error: \(e)") }
        if let e = playerError { lines.append("player error: \(e)") }
        return lines.joined(separator: "\n")
    }
}
