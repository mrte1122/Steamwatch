import XCTest
@testable import SteamwatchCore

final class SteamIDTests: XCTestCase {
    func testParsesEveryInputShape() {
        XCTAssertEqual(SteamProfileRef(parsing: "76561197960287930"), .id64("76561197960287930"))
        XCTAssertEqual(SteamProfileRef(parsing: " https://steamcommunity.com/profiles/76561197960287930/ "), .id64("76561197960287930"))
        XCTAssertEqual(SteamProfileRef(parsing: "steamcommunity.com/id/gabelogannewell"), .vanity("gabelogannewell"))
        XCTAssertEqual(SteamProfileRef(parsing: "https://steamcommunity.com/id/gabelogannewell/games?tab=all"), .vanity("gabelogannewell"))
        XCTAssertEqual(SteamProfileRef(parsing: "mrte90"), .vanity("mrte90"))
        XCTAssertNil(SteamProfileRef(parsing: ""))
        XCTAssertNil(SteamProfileRef(parsing: "https://steamcommunity.com/app/440"))
        XCTAssertNil(SteamProfileRef(parsing: "not a profile!"))
    }
}

final class DealEngineTests: XCTestCase {
    func testDemoDealsRankTargetThenLowThenFirstSale() {
        let deals = DealEngine.deals(wishlist: DemoData.wishlist, items: DemoData.items, history: DemoData.history, targets: DemoData.targets.byAppID)
        XCTAssertEqual(deals.count, 7, "only discounted wishlist games are deals")
        XCTAssertEqual(deals.first?.item.name, "Hollow Knight: Silksong")
        XCTAssertTrue(deals[0].meetsTarget)
        XCTAssertTrue(deals[0].isNewLow)
        XCTAssertEqual(deals[1].item.name, "Hades II", "target hit at exactly the target price")
        XCTAssertTrue(deals[1].meetsTarget)
        XCTAssertFalse(deals[1].isNewLow, "equal to the previous low is not a new low")
        XCTAssertEqual(deals[2].item.name, "Satisfactory", "first sale comes before routine discounts")
        XCTAssertTrue(deals[2].isFirstSale)
        XCTAssertEqual(deals[3...].map(\.item.name), ["Dave the Diver", "Balatro", "Outer Wilds", "Brotato"], "then by score: discount plus wishlist-rank boost")
        XCTAssertEqual(deals[3].score, 88, "30% + 58 for rank #2")
        XCTAssertEqual(deals[4].score, 80, "20% + 60 for rank #1")
        XCTAssertFalse(deals[5].isNewLow, "an earlier, lower sale is on record")
    }

    func testHiddenGamesAndFilters() {
        let hidden: Set<AppID> = [1030300]
        let deals = DealEngine.deals(wishlist: DemoData.wishlist, items: DemoData.items, history: DemoData.history,
                                     targets: DemoData.targets.byAppID, hidden: hidden)
        XCTAssertEqual(deals.count, 6)
        XCTAssertEqual(deals.first?.item.name, "Hades II")
        XCTAssertEqual(DealEngine.filter(deals, .targets).map(\.item.name), ["Hades II"])
        XCTAssertEqual(DealEngine.filter(deals, .lows).map(\.item.name), ["Satisfactory"])
        XCTAssertEqual(DealEngine.filter(deals, .halfOff).map(\.item.name), ["Outer Wilds"])
        XCTAssertEqual(DealEngine.filter(deals, .underTen).map(\.item.name), ["Brotato"])
        XCTAssertEqual(DealEngine.filter(deals, .all, query: "  dIvEr ").map(\.item.name), ["Dave the Diver"])

        var h = HiddenGames()
        h.hide(1); h.hide(2)
        h.prune(keeping: [2, 3])
        XCTAssertEqual(h.appIDs, [2])
        h.unhide(2)
        XCTAssertEqual(h.count, 0)
    }

    func testIgnoresStoreItemsNotOnTheWishlist() {
        let stray = StoreItem(appID: 1, name: "Stray", capsuleURL: nil, price: Price(currency: "USD", finalCents: 1, originalCents: 2, discountPercent: 50))
        let deals = DealEngine.deals(wishlist: [], items: [stray], history: PriceHistory(), targets: [:])
        XCTAssertTrue(deals.isEmpty)
    }

    func testAlertsDeduplicateAndRespectArming() {
        let deals = DealEngine.deals(wishlist: DemoData.wishlist, items: DemoData.items, history: DemoData.history, targets: DemoData.targets.byAppID)
        let quiet = DealEngine.alerts(for: deals, alreadySent: [], policy: .init(), armed: false)
        XCTAssertEqual(quiet.map(\.kind), [.target, .target], "unarmed: only target hits")

        let loud = DealEngine.alerts(for: deals, alreadySent: [], policy: .init(), armed: true)
        XCTAssertEqual(loud.map(\.kind), [.target, .target, .firstSale])

        let all = DealEngine.alerts(for: deals, alreadySent: [], policy: .init(target: true, newLow: true, firstSale: true, anySale: true), armed: true)
        XCTAssertEqual(all.count, 7)

        let sent = DealEngine.keys(for: deals)
        XCTAssertTrue(DealEngine.alerts(for: deals, alreadySent: sent, policy: .init(), armed: true).isEmpty)
        XCTAssertEqual(loud[0].title, "Hollow Knight: Silksong hit your target price")
        XCTAssertTrue(loud[0].body.hasPrefix("$11.99 (−40%), the lowest it's been"))
    }
}

final class PriceHistoryTests: XCTestCase {
    func testObserveTracksLowsAndReturnsPriorRecord() {
        var h = PriceHistory()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let full = StoreItem(appID: 7, name: "X", capsuleURL: nil, price: Price(currency: "USD", finalCents: 2000, originalCents: 2000, discountPercent: 0))
        XCTAssertNil(h.observe(full, at: t0))
        XCTAssertEqual(h.record(7)?.seenOnSale, false)

        let sale = StoreItem(appID: 7, name: "X", capsuleURL: nil, price: Price(currency: "USD", finalCents: 1200, originalCents: 2000, discountPercent: 40))
        let before = h.observe(sale, at: t0 + 86_400)
        XCTAssertEqual(before?.lowestCents, 2000)
        XCTAssertEqual(h.record(7)?.lowestCents, 1200)
        XCTAssertEqual(h.record(7)?.lowestAt, t0 + 86_400)
        XCTAssertEqual(h.record(7)?.seenOnSale, true)

        h.observe(full, at: t0 + 2 * 86_400)
        XCTAssertEqual(h.record(7)?.lowestCents, 1200, "a return to full price keeps the low")
        XCTAssertEqual(h.record(7)?.lastCents, 2000)
    }

    func testCurrencyChangeResetsTheRecord() {
        var h = PriceHistory()
        h.observe(StoreItem(appID: 1, name: "A", capsuleURL: nil, price: Price(currency: "USD", finalCents: 100, originalCents: 100, discountPercent: 0)))
        h.observe(StoreItem(appID: 1, name: "A", capsuleURL: nil, price: Price(currency: "EUR", finalCents: 900, originalCents: 900, discountPercent: 0)))
        XCTAssertEqual(h.record(1)?.lowestCents, 900)
        XCTAssertEqual(h.record(1)?.currency, "EUR")
    }

    func testPruneKeepsWishlistedAndRecent() {
        var h = PriceHistory()
        let old = Date(timeIntervalSince1970: 0)
        h.records["1"] = .init(currency: "USD", lowestCents: 1, lowestAt: old, lastCents: 1, lastSeen: old, firstSeen: old, seenOnSale: false)
        h.records["2"] = .init(currency: "USD", lowestCents: 1, lowestAt: old, lastCents: 1, lastSeen: old, firstSeen: old, seenOnSale: false)
        h.prune(keeping: [1], now: Date())
        XCTAssertEqual(Set(h.records.keys), ["1"])
    }

    func testRoundTripsThroughJSONFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("steamwatch-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = JSONFile<PriceHistory>(url: url)
        try file.save(DemoData.history)
        let loaded = file.load()
        XCTAssertEqual(loaded?.records.count, DemoData.history.records.count)
        XCTAssertEqual(loaded?.record(1030300)?.lowestCents, 1599)
    }
}

final class PlaytimeTests: XCTestCase {
    func testDailyBucketsCountOnlyIncreases() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day0 = Date(timeIntervalSince1970: Double(1_700_000_000 - 1_700_000_000 % 86_400))   // midnight UTC
        var log = PlaytimeLog()
        func g(_ a: Int, _ b: Int) -> [RecentGame] {
            [RecentGame(appID: 1, name: "A", minutesTwoWeeks: a, minutesForever: 0), RecentGame(appID: 2, name: "B", minutesTwoWeeks: b, minutesForever: 0)]
        }
        log.record(g(100, 50), at: day0 + 3600)
        log.record(g(130, 50), at: day0 + 7200)           // +30 on day 0
        log.record(g(130, 50), at: day0 + 7300)           // unchanged, within 6h: not stored
        XCTAssertEqual(log.samples.count, 2)
        log.record(g(90, 80), at: day0 + 86_400 + 3600)   // A aged out (-40 ignored), B +30 on day 1
        log.record(g(90, 95), at: day0 + 86_400 + 7200)   // B +15 on day 1

        let now = day0 + 86_400 + 10_000
        let days = log.daily(days: 3, now: now, calendar: cal)
        XCTAssertEqual(days.map(\.minutes), [0, 30, 45])
        XCTAssertEqual(log.weekMinutes(now: now, calendar: cal), 75)
        XCTAssertEqual(log.mostPlayed(days: 7, now: now)?.name, "B")
        XCTAssertNil(log.weeklyAverageMinutes(now: now, calendar: cal), "needs a week of data")
    }

    func testDemoLogHasAWeekOfBars() {
        let days = DemoData.playtime.daily(days: 7, now: DemoData.now)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.reduce(0) { $0 + $1.minutes }, 450)
        XCTAssertEqual(DemoData.playtime.mostPlayed(now: DemoData.now)?.name, "Hades")
    }
}

final class FormatTests: XCTestCase {
    func testPriceHoursAndParsing() {
        XCTAssertEqual(Format.price(1199, currency: "USD"), "$11.99")
        XCTAssertEqual(Format.hours(45), "45m")
        XCTAssertEqual(Format.hours(684), "11.4h")
        XCTAssertEqual(Format.hours(1500), "25h")
        XCTAssertEqual(Format.cents(parsing: "$14.99"), 1499)
        XCTAssertEqual(Format.cents(parsing: "15"), 1500)
        XCTAssertEqual(Format.cents(parsing: "14,99"), 1499)
        XCTAssertNil(Format.cents(parsing: "abc"))
        let now = Date()
        XCTAssertEqual(Format.relative(now - 720, now: now), "12 min ago")
        XCTAssertEqual(Format.saleEnds(now + 2.5 * 86_400, now: now), "in 2d")
    }
}

final class WireDecodingTests: XCTestCase {
    func testDecodesGetItemsWithStringPricesAndDiscounts() throws {
        let json = """
        {"response":{"store_items":[
          {"item_type":0,"id":1145350,"success":1,"name":"Hades II","appid":1145350,
           "assets":{"asset_url_format":"steam/apps/1145350/${FILENAME}?t=1","small_capsule":"abc/capsule_231x87.jpg"},
           "best_purchase_option":{"final_price_in_cents":"2249","original_price_in_cents":"2999","discount_pct":25,
             "active_discounts":[{"discount_end_date":1800000000,"discount_description":"Autumn Sale"}]}},
          {"item_type":0,"id":999,"success":1,"name":"Coming Soon","appid":999},
          {"item_type":0,"id":5,"success":0}
        ]}}
        """
        let r = try JSONDecoder().decode(GetItemsResponse.self, from: Data(json.utf8))
        let items = (r.response.store_items ?? []).compactMap { StoreItem(wire: $0) }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].price, Price(currency: "USD", finalCents: 2249, originalCents: 2999, discountPercent: 25,
                                             saleEnds: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(items[0].capsuleURL?.absoluteString, "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1145350/abc/capsule_231x87.jpg?t=1")
        XCTAssertNil(items[1].price)
    }

    func testClientSurfacesKeyAndPrivacyErrors() async {
        struct Stub: HTTPTransport {
            let status: Int
            func get(_ url: URL) async throws -> (Data, Int) { (Data("{}".utf8), status) }
        }
        let noKey = SteamClient(transport: Stub(status: 200))
        do { _ = try await noKey.recentlyPlayed(steamID: "1"); XCTFail() } catch { XCTAssertEqual(error as? SteamError, .missingAPIKey) }
        let badKey = SteamClient(transport: Stub(status: 403), apiKey: "x")
        do { _ = try await badKey.recentlyPlayed(steamID: "1"); XCTFail() } catch { XCTAssertEqual(error as? SteamError, .badAPIKey) }
        let limited = SteamClient(transport: Stub(status: 429))
        do { _ = try await limited.wishlist(steamID: "1"); XCTFail() } catch { XCTAssertEqual(error as? SteamError, .rateLimited) }
    }
}
