import Combine
import AppKit
import Foundation
import Network
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
    /// Games watched through store search, on top of the Steam wishlist.
    @Published private(set) var watchlist = Watchlist()
    /// Wishlist plus watched games: everything the store is checked for.
    private var watched: [WishlistEntry] { wishlist + watchlist.asWishlistEntries(excluding: Set(wishlist.map(\.appID))) }
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
    private let watchlistFile = JSONFile<Watchlist>(url: directory.appendingPathComponent("watchlist.json"))
    private let suggestionsFile = JSONFile<SuggestionsCache>(url: directory.appendingPathComponent("suggestions.json"))

    var steamID: String { UserDefaults.standard.string(forKey: SettingsKey.steamID) ?? "" }
    var apiKey: String? { Keychain.load(.apiKey) }
    var needsSetup: Bool { steamID.isEmpty && !Demo.isActive }
    var hasAPIKey: Bool { Demo.isActive ? !previewNoKey : !(apiKey ?? "").isEmpty }
    /// Screenshots only: show demo mode as if no key were set.
    var previewNoKey = false
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
        watchlist = watchlistFile.load() ?? Watchlist()
        suggestions = suggestionsFile.load()
        if let cached = cacheFile.load() { apply(cached) }
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        scheduleTimer()
        Task { await refresh() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleTimer() }
        }
        // After sleep or an outage the 30-minute timer can leave prices hours old; catch up instead.
        // A few seconds' delay lets Wi-Fi reconnect after wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task { @MainActor in self?.catchUp() }
            }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                if path.status == .satisfied {
                    if self.networkWasDown { self.networkWasDown = false; self.catchUp() }
                } else {
                    self.networkWasDown = true
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Steamwatch.network"))
        handleNotificationActions()
    }

    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false

    /// Refresh after wake or reconnect unless the last reading is under five minutes old. Not forced,
    /// so a rate-limit cooldown still holds.
    private func catchUp() {
        if let last = lastUpdated, Date().timeIntervalSince(last) < 300 { return }
        Task { await refresh() }
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
        suggestions = nil
        owned = nil
        try? FileManager.default.removeItem(at: suggestionsFile.url)
        deals = []; recentGames = []; me = nil; friendsOnline = []; wishlistCount = 0; items = [:]; wishlist = []
        lastUpdated = nil; lastError = nil; playerError = nil
        try? historyFile.save(history)
        try? playtimeFile.save(playtime)
        if !Demo.isActive { try? hiddenFile.save(hidden) }
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
            let watched = wishlist + watchlist.asWishlistEntries(excluding: Set(wishlist.map(\.appID)))
            let ids = Set(watched.map(\.appID))
            let fetched = watched.isEmpty ? SteamClient.StoreResult(items: [], missing: [], error: nil)
                                          : await client.storeItems(partial: watched.map(\.appID))
            // Fill gaps from the last reading so a game doesn't vanish because its batch failed.
            let carried = fetched.missing.compactMap { items[$0] }
            let merged = fetched.items + carried
            staleCount = carried.count
            failed = fetched.error

            hidden.prune(keeping: ids)
            if !Demo.isActive { try? hiddenFile.save(hidden) }
            let fresh = DealEngine.deals(wishlist: watched, items: merged, history: history, targets: targets.byAppID, hidden: hidden.appIDs)
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
        if failed == nil { Task { await refreshSuggestions() } }
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
        // The library changes rarely; every six hours keeps owned games out of For You.
        if owned == nil || Date().timeIntervalSince(ownedFetchedAt) > 6 * 3600 {
            if let games = try? await client.ownedGames(steamID: id) { owned = games; ownedFetchedAt = Date() }
        }
        if UserDefaults.standard.bool(forKey: SettingsKey.showFriends) {
            do {
                let ids = try await client.friendIDs(steamID: id)
                friendsPrivate = false
                let online = ids.isEmpty ? [] : try await client.playerSummaries(ids).filter(\.isOnline)
                // In-game friends first, then alphabetical.
                friendsOnline = online.sorted { a, b in
                    if (a.currentGame == nil) != (b.currentGame == nil) { return a.currentGame != nil }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            } catch SteamError.privateFriends {
                // Not an error: the key works, the user just keeps friends private.
                friendsPrivate = true
                friendsOnline = []
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
    func clearPreviewSaleEvent() { if Demo.isActive { saleEvent = nil } }

    // MARK: Muting and quiet hours

    /// Games that stay in the list but never notify.
    @Published private(set) var muted: Set<AppID> = Set(UserDefaults.standard.array(forKey: SettingsKey.mutedApps) as? [Int] ?? [])
    /// Alerts that arrived during quiet hours, delivered on the first refresh after.
    private var heldAlerts: [DealAlert] = []

    func toggleMute(_ appID: AppID) {
        if muted.contains(appID) { muted.remove(appID) } else { muted.insert(appID) }
        heldAlerts.removeAll { muted.contains($0.deal.item.appID) }
        if !Demo.isActive { UserDefaults.standard.set(Array(muted).sorted(), forKey: SettingsKey.mutedApps) }
    }

    var quietHours: QuietHours? {
        let d = UserDefaults.standard
        guard d.bool(forKey: SettingsKey.quietEnabled) else { return nil }
        return QuietHours(startHour: d.integer(forKey: SettingsKey.quietStart), endHour: d.integer(forKey: SettingsKey.quietEnd))
    }

    /// Wires the banner buttons; called once at launch.
    private func handleNotificationActions() {
        notifier.onAction = { [weak self] action, appID in
            guard let self else { return }
            switch action {
            case .hide: self.hide(appID)
            case .mute: if !self.muted.contains(appID) { self.toggleMute(appID) }
            case .open: break
            }
        }
    }

    private func notify(_ deals: [Deal]) {
        let d = UserDefaults.standard
        var sent = Set(d.stringArray(forKey: SettingsKey.sentAlerts) ?? [])
        var policy = DealEngine.Policy(target: d.bool(forKey: SettingsKey.notifyTarget), newLow: d.bool(forKey: SettingsKey.notifyNewLow),
                                       firstSale: d.bool(forKey: SettingsKey.notifyFirstSale), anySale: d.bool(forKey: SettingsKey.notifyAnySale))
        policy.rule = rule
        let fresh = d.bool(forKey: SettingsKey.notificationsEnabled)
            ? DealEngine.alerts(for: deals, alreadySent: sent, policy: policy, armed: armed).filter { !muted.contains($0.deal.item.appID) } : []
        // Overnight, hold everything; the first refresh after quiet hours delivers it (as a digest if many).
        let alerts: [DealAlert]
        if let quiet = quietHours, quiet.contains(Date()) {
            heldAlerts += fresh.filter { a in !heldAlerts.contains { $0.key == a.key } }
            alerts = []
        } else {
            let stillOnSale = Set(deals.map(\.id))
            alerts = heldAlerts.filter { stillOnSale.contains($0.deal.item.appID) } + fresh
            heldAlerts = []
        }
        // Target hits post on their own; a burst of other alerts, or any during a big sale, becomes one digest.
        let plan = NotificationPlan.plan(alerts, totalOnSale: deals.count, event: saleEvent)
        for a in plan.individual { notifier.post(a) }
        // (Nothing is posted while alerts is empty, which covers quiet hours.)
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
            deals = DealEngine.deals(wishlist: watched, items: cached.items, history: history, targets: targets.byAppID, hidden: hidden.appIDs)
            lastUpdated = cached.fetchedAt
        }
    }

    // MARK: Targets and hiding

    /// The user's standing deal rule from Settings, or nil when it's off.
    var rule: DealRule? {
        let d = UserDefaults.standard
        guard d.bool(forKey: SettingsKey.ruleEnabled) else { return nil }
        let rating = d.integer(forKey: SettingsKey.ruleMinRating), price = d.integer(forKey: SettingsKey.ruleMaxPrice)
        return DealRule(minDiscount: d.integer(forKey: SettingsKey.ruleMinDiscount),
                        minRating: rating > 0 ? rating : nil, maxPriceCents: price > 0 ? price : nil)
    }

    // MARK: Suggestions

    @Published private(set) var suggestions: SuggestionsCache?
    @Published private(set) var isSuggesting = false
    /// Why the last suggestion fetch produced nothing, for diagnostics.
    @Published private(set) var suggestionNote: String?
    @Published private(set) var dismissed: Set<AppID> = Set(UserDefaults.standard.array(forKey: SettingsKey.dismissedSuggestions) as? [Int] ?? [])
    /// Owned games, fetched with the API key so suggestions skip them; nil without a key.
    private var owned: Set<AppID>?
    private var ownedFetchedAt = Date.distantPast
    /// GetFriendList refused: the friends list is private (the key itself is fine).
    @Published private(set) var friendsPrivate = false
    private var tagNameCache: [Int: String] = [:]

    /// Games the user marked "I already own this"; works without an API key.
    @Published private(set) var ownedManual: Set<AppID> = Set(UserDefaults.standard.array(forKey: SettingsKey.ownedManual) as? [Int] ?? [])

    /// Owned per Steam (with a key) or per the user.
    func isOwned(_ appID: AppID) -> Bool { ownedManual.contains(appID) || (owned?.contains(appID) ?? false) }

    func markOwned(_ appID: AppID, _ yes: Bool = true) {
        if yes { ownedManual.insert(appID) } else { ownedManual.remove(appID) }
        if !Demo.isActive { UserDefaults.standard.set(Array(ownedManual).sorted(), forKey: SettingsKey.ownedManual) }
    }

    /// What the For You tab shows: last results minus anything since watched, wishlisted, owned or dismissed.
    var visibleSuggestions: [Suggestion] {
        (suggestions?.suggestions ?? []).filter { !isWatching($0.id) && !dismissed.contains($0.id) && !isOwned($0.id) }
    }

    /// Save a Web API key from anywhere in the UI, then pick up owned games, playtime and friends.
    func saveAPIKey(_ key: String) {
        Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), .apiKey)
        owned = nil
        ownedFetchedAt = .distantPast
        Task {
            await refresh(force: true)
            await refreshSuggestions(force: true)
        }
    }

    func tagNames(for s: Suggestion) -> [String] { suggestions?.names(for: s) ?? [] }

    func dismissSuggestion(_ appID: AppID) {
        dismissed.insert(appID)
        if !Demo.isActive { UserDefaults.standard.set(Array(dismissed).sorted(), forKey: SettingsKey.dismissedSuggestions) }
    }

    func resetDismissedSuggestions() {
        dismissed = []
        if !Demo.isActive { UserDefaults.standard.set([Int](), forKey: SettingsKey.dismissedSuggestions) }
    }

    /// Learn taste from the wishlist's store tags, ask Steam for discounted games under the top
    /// tags, and keep the best fits. Runs at most twice a day; it's 2–3 extra requests.
    func refreshSuggestions(force: Bool = false) async {
        // One fetch at a time: a caller arriving mid-fetch waits for it instead of returning early
        // with stale results.
        if let running = suggestTask { await running.value; if !force { return } }
        let t = Task { await performSuggestions(force: force) }
        suggestTask = t
        await t.value
        suggestTask = nil
    }

    private var suggestTask: Task<Void, Never>?

    private func performSuggestions(force: Bool) async {
        guard !Demo.isActive else { return }
        guard !needsSetup else { suggestionNote = "no Steam account connected"; return }
        guard UserDefaults.standard.bool(forKey: SettingsKey.showSuggestions) else { suggestionNote = "suggestions are off in Settings"; return }
        if !force, let last = suggestions?.fetchedAt, Date().timeIntervalSince(last) < 12 * 3600 { return }
        let priorities = Dictionary(wishlist.map { ($0.appID, $0.priority) }, uniquingKeysWith: { a, _ in a })
        let profile = TasteProfile.build(from: Array(items.values), priorities: priorities)
        guard !profile.isEmpty else { suggestionNote = "no store tags yet for \(items.count) items"; return }   // store data predates tag fetching
        isSuggesting = true
        defer { isSuggesting = false }
        let client = client()
        do {
            if owned == nil, hasAPIKey { owned = try? await client.ownedGames(steamID: steamID) }
            let candidates = try await client.discountedGames(withAnyTag: profile.top(4))
            let exclude = Set(wishlist.map(\.appID)).union(watchlist.appIDs).union(dismissed).union(owned ?? []).union(ownedManual)
            let ranked = SuggestionEngine.rank(candidates, profile: profile, exclude: exclude)
            suggestionNote = "top tags \(profile.top(4)), \(candidates.count) candidates, \(exclude.count) excluded, \(ranked.count) kept"
            if tagNameCache.isEmpty { tagNameCache = (try? await client.tagNames()) ?? [:] }
            let used = Set(ranked.flatMap(\.matchedTags))
            let names = Dictionary(uniqueKeysWithValues: used.compactMap { id in tagNameCache[id].map { (String(id), $0) } })
            let cache = SuggestionsCache(fetchedAt: Date(), suggestions: ranked, tagNames: names)
            suggestions = cache
            try? suggestionsFile.save(cache)
        } catch {
            // Suggestions are a nice-to-have: keep the last ones and try again next refresh.
            suggestionNote = error.localizedDescription
        }
    }

    // MARK: Account

    /// Accounts the Steam client on this Mac has signed in with, for one-click setup. Read on demand:
    /// it's a small local file and changes when the user switches accounts in Steam.
    var localAccounts: [LocalSteamAccount] { Demo.isActive ? [] : LocalSteam.accounts() }

    func useAccount(_ account: LocalSteamAccount) {
        let d = UserDefaults.standard
        let changed = d.string(forKey: SettingsKey.steamID) != account.steamID
        d.set(account.steamID, forKey: SettingsKey.steamID)
        d.set("https://steamcommunity.com/profiles/\(account.steamID)/", forKey: SettingsKey.profileInput)
        if changed { resetForNewProfile() } else { Task { await refresh(force: true) } }
    }

    // MARK: Watching by search

    @Published private(set) var searchResults: [StoreItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var searchError: String?
    private var searchTask: Task<Void, Never>?

    /// Debounced store search; a newer query cancels the one in flight.
    func search(_ term: String) {
        searchTask?.cancel()
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { searchResults = []; isSearching = false; searchError = nil; return }
        if Demo.isActive {
            searchResults = DemoData.items.filter { $0.name.range(of: q, options: .caseInsensitive) != nil }
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                let found = try await self.client().search(q)
                guard !Task.isCancelled else { return }
                self.searchResults = found
                self.searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.searchError = error.localizedDescription
            }
            self.isSearching = false
        }
    }

    func isOnWishlist(_ appID: AppID) -> Bool { wishlist.contains { $0.appID == appID } }
    func isWatching(_ appID: AppID) -> Bool { isOnWishlist(appID) || watchlist.contains(appID) }

    /// Watch a game found by search, optionally with a price limit, and price-check it right away.
    func watch(_ item: StoreItem, limitCents: Int?) {
        if !isOnWishlist(item.appID) {
            watchlist.add(item.appID, name: item.name)
            if !Demo.isActive { try? watchlistFile.save(watchlist) }
        }
        items[item.appID] = items[item.appID] ?? item
        if let limitCents { targets[item.appID] = limitCents; if !Demo.isActive { try? targetsFile.save(targets) } }
        rerank()
        Task { await refresh(force: true) }
    }

    /// Stop watching a searched-for game. Its limit goes too unless it's also on the wishlist.
    func unwatch(_ appID: AppID) {
        watchlist.remove(appID)
        if !Demo.isActive { try? watchlistFile.save(watchlist) }
        if !isOnWishlist(appID) { targets[appID] = nil; if !Demo.isActive { try? targetsFile.save(targets) } }
        rerank()
    }

    func setTarget(_ cents: Int?, for appID: AppID) {
        targets[appID] = cents
        if !Demo.isActive { try? targetsFile.save(targets) }
        rerank()
    }

    func hide(_ appID: AppID) {
        if let d = deals.first(where: { $0.id == appID }) { hiddenDeals.append(d) }
        hidden.hide(appID)
        if !Demo.isActive { try? hiddenFile.save(hidden) }
        rerank()
    }

    func unhide(_ appID: AppID) {
        hidden.unhide(appID)
        if !Demo.isActive { try? hiddenFile.save(hidden) }
        rerank()
    }

    func unhideAll() {
        hidden = HiddenGames()
        if !Demo.isActive { try? hiddenFile.save(hidden) }
        rerank()
    }

    /// Re-run the engine without a network round trip, over the last reading's wishlist and items.
    private func rerank() {
        if Demo.isActive {
            let extra = watchlist.asWishlistEntries(excluding: Set(DemoData.wishlist.map(\.appID)))
            deals = DealEngine.deals(wishlist: DemoData.wishlist + extra, items: Array(items.values), history: DemoData.history,
                                     targets: targets.byAppID, hidden: hidden.appIDs)
            return
        }
        guard !watched.isEmpty else { return }
        deals = DealEngine.deals(wishlist: watched, items: Array(items.values), history: historyWithoutCurrent(), targets: targets.byAppID,
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
        suggestions = DemoData.suggestions
        lastUpdated = Date().addingTimeInterval(-12 * 60)
        lastError = nil
    }

    func diagnosticsText() -> String {
        // Shared in public bug reports, so no Steam ID, profile name or key: just whether they're set.
        let mac = ProcessInfo.processInfo.operatingSystemVersion
        var lines = ["Steamwatch \(SteamClient.version) · macOS \(mac.majorVersion).\(mac.minorVersion).\(mac.patchVersion)",
                     "steam account: \(steamID.isEmpty ? "not set" : "connected")", "api key: \(hasAPIKey ? "set" : "none")"]
        if let u = lastUpdated { lines.append("updated: \(u)") }
        lines.append("watching: \(watchlist.count) beyond the wishlist")
        lines.append("wishlist: \(wishlistCount) · on sale: \(deals.count) · hidden: \(hidden.count) · targets: \(targets.cents.count)"
                     + (staleCount > 0 ? " · stale prices: \(staleCount)" : ""))
        if let until = rateLimitedUntil, until > Date() { lines.append("rate limited until: \(until)") }
        lines.append("owned: \(owned.map { "\($0.count) from Steam" } ?? "unknown (no key)") · \(ownedManual.count) marked by hand")
        if let s = suggestions { lines.append("suggestions: \(visibleSuggestions.count) shown of \(s.suggestions.count), fetched \(s.fetchedAt)") }
        if let e = saleEvent { lines.append("sale event: since \(e.started), +\(e.extra(deals)) deals" + (e.ends.map { ", most end \($0)" } ?? "")) }
        for d in deals { lines.append("  \(d.item.name): \(Format.price(d.price.finalCents, currency: d.price.currency)) −\(d.price.discountPercent)%\(d.meetsTarget ? " TARGET" : "")\(d.isNewLow ? " LOW" : "")\(d.isFirstSale ? " FIRST" : "")") }
        lines.append("played 2 wk: \(Format.hours(twoWeekMinutes)) · friends online: \(friendsOnline.count)")
        if let e = lastError { lines.append("error: \(e)") }
        if let e = playerError { lines.append("player error: \(e)") }
        return lines.joined(separator: "\n")
    }
}
