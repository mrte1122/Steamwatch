import Foundation

/// Sample data for `--demo`, screenshots and tests. Names are real games; prices are made up.
public enum DemoData {
    public static let now = Date()

    /// Sorted: Silksong (target + new low), Hades II (at target), Satisfactory (first sale),
    /// then by score: Dave the Diver (#2, 30+58), Balatro (#1, 20+60), Outer Wilds (50), Brotato (30).
    public static let items: [StoreItem] = [
        game(1030300, "Hollow Knight: Silksong", 1999, 1199, 40, ends: 4),
        game(1145350, "Hades II", 2999, 2249, 25, ends: 2),
        game(753640, "Outer Wilds", 2499, 1249, 50, ends: 5),
        game(526870, "Satisfactory", 3999, 3199, 20, ends: 6),
        game(1942280, "Brotato", 499, 349, 30, ends: 3),
        game(2379780, "Balatro", 1499, 1199, 20, ends: 9),
        game(1868140, "Dave the Diver", 1999, 1399, 30, ends: 1),
        game(1091500, "Cyberpunk 2077", 5999, 5999, 0),
        game(2358720, "Black Myth: Wukong", 5999, 5999, 0),
        game(1245620, "Elden Ring", 5999, 5999, 0),
        game(892970, "Valheim", 1999, 1999, 0),
    ]

    /// Balatro is ranked #1 and Dave the Diver #2 on the demo wishlist; the rest are unranked.
    public static let wishlist: [WishlistEntry] = items.enumerated().map {
        WishlistEntry(appID: $1.appID, priority: $1.appID == 2379780 ? 1 : $1.appID == 1868140 ? 2 : 0,
                      added: now.addingTimeInterval(-Double($0 + 1) * 30 * 86_400))
    }

    public static let targets = Targets(cents: ["1030300": 1500, "1145350": 2249])

    /// Seeded so Silksong is a new low below its target, Hades II exactly at its target, Satisfactory
    /// a first sale, and the others routine discounts with an earlier low on record.
    public static var history: PriceHistory {
        var h = PriceHistory()
        let past = now.addingTimeInterval(-60 * 86_400)
        let lows: [AppID: Int] = [1030300: 1599, 1145350: 2249, 753640: 999, 1942280: 299, 2379780: 1199, 1868140: 1299]
        for item in items {
            guard let p = item.price else { continue }
            let lowest = lows[item.appID] ?? p.originalCents
            h.records[String(item.appID)] = .init(currency: "USD", lowestCents: lowest, lowestAt: past, lastCents: p.originalCents,
                                                  lastSeen: now.addingTimeInterval(-3600), firstSeen: past, seenOnSale: lows[item.appID] != nil)
        }
        return h
    }

    public static let recentGames: [RecentGame] = [
        RecentGame(appID: 548430, name: "Deep Rock Galactic", minutesTwoWeeks: 246, minutesForever: 9_120),
        RecentGame(appID: 1145360, name: "Hades", minutesTwoWeeks: 190, minutesForever: 4_300),
        RecentGame(appID: 2379780, name: "Balatro", minutesTwoWeeks: 150, minutesForever: 880),
        RecentGame(appID: 892970, name: "Valheim", minutesTwoWeeks: 98, minutesForever: 2_010),
    ]

    /// A week of samples so the daily chart has bars.
    public static var playtime: PlaytimeLog {
        var log = PlaytimeLog()
        let perDay = [40, 15, 75, 25, 95, 140, 60]
        var running = recentGames.map { RecentGame(appID: $0.appID, name: $0.name, minutesTwoWeeks: 0, minutesForever: $0.minutesForever) }
        let start = Calendar.current.startOfDay(for: now).addingTimeInterval(-7 * 86_400 + 3600)
        log.record(running, at: start)
        for (i, minutes) in perDay.enumerated() {
            let game = i % running.count
            running[game] = RecentGame(appID: running[game].appID, name: running[game].name,
                                       minutesTwoWeeks: running[game].minutesTwoWeeks + minutes, minutesForever: running[game].minutesForever)
            log.record(running, at: start.addingTimeInterval(Double(i + 1) * 86_400 - 1800))
        }
        return log
    }

    public static let me = PlayerSummary(steamID: "76561197960287930", name: "tyler", avatarURL: nil, isOnline: true, currentGame: nil, currentGameID: nil)

    public static let friendsOnline: [PlayerSummary] = [
        PlayerSummary(steamID: "1", name: "mags", avatarURL: nil, isOnline: true, currentGame: "Deep Rock Galactic", currentGameID: 548430),
        PlayerSummary(steamID: "2", name: "jordan_k", avatarURL: nil, isOnline: true, currentGame: "Balatro", currentGameID: 2379780),
        PlayerSummary(steamID: "3", name: "pxl", avatarURL: nil, isOnline: true, currentGame: nil, currentGameID: nil),
    ]

    private static let reviews: [AppID: (Int, Int, String)] = [
        1030300: (93, 48_200, "Very Positive"), 1145350: (95, 115_457, "Overwhelmingly Positive"), 753640: (96, 71_000, "Overwhelmingly Positive"),
        526870: (97, 210_000, "Overwhelmingly Positive"), 1942280: (96, 58_000, "Overwhelmingly Positive"), 2379780: (97, 140_000, "Overwhelmingly Positive"),
        1868140: (92, 64_000, "Very Positive"), 1091500: (85, 700_000, "Very Positive"), 2358720: (91, 420_000, "Very Positive"),
        1245620: (92, 760_000, "Very Positive"), 892970: (94, 480_000, "Very Positive"),
    ]
    private static let noMac: Set<AppID> = [526870, 1091500, 2358720, 1245620]

    private static func game(_ id: AppID, _ name: String, _ original: Int, _ final: Int, _ pct: Int, ends: Int? = nil) -> StoreItem {
        StoreItem(appID: id, name: name, capsuleURL: URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(id)/capsule_231x87.jpg"),
                  price: Price(currency: "USD", finalCents: final, originalCents: original, discountPercent: pct,
                               saleEnds: ends.map { now.addingTimeInterval(Double($0) * 86_400 + 7200) }),
                  reviews: reviews[id].map { ReviewSummary(percentPositive: $0.0, count: $0.1, label: $0.2) },
                  platforms: Platforms(windows: true, mac: !noMac.contains(id), linux: false, deck: id == 526870 ? .playable : .verified))
    }
}
