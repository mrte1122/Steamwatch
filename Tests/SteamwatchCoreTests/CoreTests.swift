import XCTest
@testable import SteamwatchCore

/// Prices format with the locale's currency symbol; pin en_US so assertions hold everywhere.
private let pinLocale: Void = { Format.locale = Locale(identifier: "en_US") }()


final class SteamIDTests: XCTestCase {
    override func setUp() { super.setUp(); _ = pinLocale }

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
    override func setUp() { super.setUp(); _ = pinLocale }

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

        XCTAssertEqual(DealEngine.filter(deals, .mac).count, 5, "Satisfactory has no Mac build")
        XCTAssertEqual(DealEngine.filter(deals, .deck).count, 6, "playable counts as Deck-friendly")

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

final class DealSortTests: XCTestCase {
    override func setUp() { super.setUp(); _ = pinLocale }

    let deals = DealEngine.deals(wishlist: DemoData.wishlist, items: DemoData.items, history: DemoData.history, targets: DemoData.targets.byAppID)

    func testSorts() {
        XCTAssertEqual(DealSort.best.sorted(deals).map(\.id), deals.map(\.id))
        XCTAssertEqual(DealSort.rating.sorted(deals).prefix(3).map(\.item.name), ["Satisfactory", "Balatro", "Outer Wilds"])
        XCTAssertEqual(DealSort.discount.sorted(deals).first?.item.name, "Outer Wilds")
        XCTAssertEqual(DealSort.price.sorted(deals).first?.item.name, "Brotato")
        XCTAssertEqual(DealSort.endingSoon.sorted(deals).first?.item.name, "Dave the Diver")
        XCTAssertEqual(DealSort.name.sorted(deals).first?.item.name, "Balatro")
    }

    func testRatingSortDiscountsTinyReviewCounts() {
        func deal(_ id: AppID, _ pct: Int, _ count: Int) -> Deal {
            Deal(item: StoreItem(appID: id, name: "\(id)", capsuleURL: nil, price: nil, reviews: ReviewSummary(percentPositive: pct, count: count, label: "")),
                 price: Price(currency: "USD", finalCents: 1, originalCents: 2, discountPercent: 50), lowestSeenCents: nil, targetCents: nil, isFirstSale: false)
        }
        let unrated = Deal(item: StoreItem(appID: 3, name: "3", capsuleURL: nil, price: nil),
                           price: Price(currency: "USD", finalCents: 1, originalCents: 2, discountPercent: 50), lowestSeenCents: nil, targetCents: nil, isFirstSale: false)
        let sorted = DealSort.rating.sorted([unrated, deal(1, 100, 12), deal(2, 95, 20_000)])
        XCTAssertEqual(sorted.map(\.id), [2, 1, 3], "95% from 20k reviews beats 100% from 12; unrated last")
    }

    func testCompactNumbers() {
        XCTAssertEqual(Format.compact(840), "840")
        XCTAssertEqual(Format.compact(1_200), "1.2k")
        XCTAssertEqual(Format.compact(3_000), "3k")
        XCTAssertEqual(Format.compact(115_457), "115k")
        XCTAssertEqual(Format.compact(1_260_000), "1.3M")
    }
}

final class SaleDigestTests: XCTestCase {
    override func setUp() { super.setUp(); _ = pinLocale }

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func deal(_ id: AppID, pct: Int = 50, endsIn days: Double? = 3, target: Int? = nil, first: Bool = false, low: Int? = nil) -> Deal {
        Deal(item: StoreItem(appID: id, name: "Game \(id)", capsuleURL: nil, price: nil),
             price: Price(currency: "USD", finalCents: 1000, originalCents: 2000, discountPercent: pct,
                          saleEnds: days.map { now.addingTimeInterval($0 * 86_400 + Double(id % 3) * 3600) }),
             lowestSeenCents: low, targetCents: target, isFirstSale: first)
    }

    func testEventStartsOnAJumpNotOnFirstRun() {
        let before = Set((1...10).map { $0 })
        let deals = (1...60).map { deal($0) }
        XCTAssertNil(SaleEvent.evaluate(nil, previousIDs: [], deals: deals, wishlistCount: 400, now: now), "first run is a baseline")
        XCTAssertNil(SaleEvent.evaluate(nil, previousIDs: before, deals: (1...20).map { deal($0) }, wishlistCount: 400, now: now),
                     "10 new is under the 20 threshold for 400 games")
        let event = SaleEvent.evaluate(nil, previousIDs: before, deals: deals, wishlistCount: 400, now: now)
        XCTAssertEqual(event?.baselineCount, 10)
        XCTAssertEqual(event?.extra(deals), 50)
        XCTAssertNotNil(event?.ends)
        XCTAssertEqual(event!.ends!.timeIntervalSince(now), 3 * 86_400 + 2 * 3600, accuracy: 1, "latest hour on the common day")
    }

    func testEventContinuesThenEnds() {
        let event = SaleEvent(started: now, baselineCount: 10, ends: now.addingTimeInterval(3 * 86_400))
        XCTAssertNotNil(SaleEvent.evaluate(event, previousIDs: [], deals: (1...40).map { deal($0) }, wishlistCount: 400, now: now))
        XCTAssertNil(SaleEvent.evaluate(event, previousIDs: [], deals: (1...15).map { deal($0) }, wishlistCount: 400, now: now),
                     "back near the baseline")
        XCTAssertNil(SaleEvent.evaluate(event, previousIDs: [], deals: (1...40).map { deal($0, endsIn: nil) }, wishlistCount: 400,
                                        now: now.addingTimeInterval(4 * 86_400)), "past the clustered end")
    }

    func testPlanKeepsTargetsAndDigestsTheRest() {
        let alerts = [DealAlert(kind: .target, deal: deal(1, target: 2000)), DealAlert(kind: .target, deal: deal(2, target: 2000)),
                      DealAlert(kind: .newLow, deal: deal(3, low: 1500)), DealAlert(kind: .firstSale, deal: deal(4, first: true))]
        let quiet = NotificationPlan.plan(alerts, totalOnSale: 20, event: nil)
        XCTAssertEqual(quiet.individual.count, 4, "a few alerts post one by one")
        XCTAssertNil(quiet.digest)

        let many = alerts + (5...12).map { DealAlert(kind: .newLow, deal: deal($0, low: 1500)) }
        let busy = NotificationPlan.plan(many, totalOnSale: 40, event: nil)
        XCTAssertEqual(busy.individual.map(\.kind), [.target, .target])
        XCTAssertEqual(busy.digest?.alerts.count, 10)
        XCTAssertEqual(busy.digest?.title, "10 wishlist games dropped in price")
        XCTAssertTrue(busy.digest!.body.hasPrefix("1 first sales · 9 new lows\nGame 3 −50%, Game 4 −50%"))

        let event = SaleEvent(started: now, baselineCount: 10, ends: Date().addingTimeInterval(3 * 86_400 + 60))
        let sale = NotificationPlan.plan(Array(alerts.prefix(3)), totalOnSale: 120, event: event)
        XCTAssertEqual(sale.individual.count, 2, "during a sale even one non-target alert goes in the digest")
        XCTAssertEqual(sale.digest?.title, "Steam sale: 120 wishlist games on sale")
        XCTAssertTrue(sale.digest!.body.hasPrefix("1 new lows · most end in 3d"))

        let lotsOfTargets = (1...5).map { DealAlert(kind: .target, deal: deal($0, target: 2000)) }
        let capped = NotificationPlan.plan(lotsOfTargets, totalOnSale: 5, event: nil)
        XCTAssertEqual(capped.individual.count, 5, "overflow targets under the digest threshold still post")
        let capped2 = NotificationPlan.plan((1...8).map { DealAlert(kind: .target, deal: deal($0, target: 2000)) }, totalOnSale: 8, event: nil)
        XCTAssertEqual(capped2.individual.count, 3)
        XCTAssertEqual(capped2.digest?.body.hasPrefix("5 under target"), true)
    }
}

final class WatchlistTests: XCTestCase {
    override func setUp() { super.setUp(); _ = pinLocale }

    func testWatchedGamesJoinTheDealsAndPriceCutsHitTargets() {
        var watch = Watchlist()
        watch.add(367520, name: "Hollow Knight")
        watch.add(1030300, name: "Hollow Knight: Silksong")   // already wishlisted: not duplicated
        let wishIDs = Set(DemoData.wishlist.map(\.appID))
        let extra = watch.asWishlistEntries(excluding: wishIDs)
        XCTAssertEqual(extra.map(\.appID), [367520])

        // Full price, no discount, but the regular price is now under the limit.
        let cut = StoreItem(appID: 367520, name: "Hollow Knight", capsuleURL: nil,
                            price: Price(currency: "USD", finalCents: 999, originalCents: 999, discountPercent: 0))
        var targets = DemoData.targets
        targets[367520] = 1000
        let deals = DealEngine.deals(wishlist: DemoData.wishlist + extra, items: DemoData.items + [cut],
                                     history: DemoData.history, targets: targets.byAppID)
        let hk = deals.first { $0.id == 367520 }
        XCTAssertNotNil(hk, "a price cut to the limit counts")
        XCTAssertEqual(hk?.meetsTarget, true)
        XCTAssertEqual(DealAlert(kind: .target, deal: hk!).body, "$9.99, a new regular price")

        targets[367520] = 900
        XCTAssertNil(DealEngine.deals(wishlist: extra, items: [cut], history: PriceHistory(), targets: targets.byAppID).first,
                     "above the limit and not discounted: not a deal")

        watch.remove(367520)
        XCTAssertEqual(watch.appIDs, [1030300])
    }

    func testDecodesStoreSearch() throws {
        let json = """
        {"total":3,"items":[
          {"type":"app","name":"Hollow Knight","id":367520,"price":{"currency":"USD","initial":1499,"final":749},"tiny_image":"https://x/capsule.jpg"},
          {"type":"app","name":"Counter-Strike 2","id":730,"tiny_image":"https://x/cs2.jpg"},
          {"type":"sub","name":"Bundle","id":1,"price":{"currency":"USD","initial":100,"final":50}}
        ]}
        """
        let r = try JSONDecoder().decode(StoreSearchResponse.self, from: Data(json.utf8))
        let items = (r.items ?? []).compactMap { StoreItem(search: $0) }
        XCTAssertEqual(items.map(\.appID), [367520, 730], "packages are skipped")
        XCTAssertEqual(items[0].price, Price(currency: "USD", finalCents: 749, originalCents: 1499, discountPercent: 50))
        XCTAssertTrue(items[1].isFree)
        XCTAssertNil(items[1].price)
    }

    func testSearchHitsTheStoreHost() async throws {
        final class Capture: HTTPTransport, @unchecked Sendable {
            var url: URL?
            func get(_ url: URL) async throws -> (Data, Int) { self.url = url; return (Data(#"{"total":0,"items":[]}"#.utf8), 200) }
        }
        let t = Capture()
        let none = try await SteamClient(transport: t, countryCode: "GB").search("  hades ")
        XCTAssertTrue(none.isEmpty)
        let comps = URLComponents(url: t.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.host, "store.steampowered.com")
        XCTAssertEqual(comps.path, "/api/storesearch/")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "term" }?.value, "hades")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "cc" }?.value, "GB")
        let blank = try await SteamClient(transport: t).search("   ")
        XCTAssertTrue(blank.isEmpty)
    }
}

final class DealRuleTests: XCTestCase {
    override func setUp() { super.setUp(); _ = pinLocale }

    let deals = DealEngine.deals(wishlist: DemoData.wishlist, items: DemoData.items, history: DemoData.history, targets: DemoData.targets.byAppID)

    func testRuleMatching() {
        let half = DealRule(minDiscount: 50)
        XCTAssertEqual(deals.filter(half.matches).map(\.item.name), ["Outer Wilds"])
        let rated = DealRule(minDiscount: 20, minRating: 96)
        XCTAssertEqual(Set(deals.filter(rated.matches).map(\.item.name)), ["Satisfactory", "Balatro", "Outer Wilds", "Brotato"])
        let cheap = DealRule(minDiscount: 20, minRating: 96, maxPriceCents: 1200)
        XCTAssertEqual(Set(deals.filter(cheap.matches).map(\.item.name)), ["Balatro", "Brotato"])
        XCTAssertEqual(cheap.summary(), "20%+ off · rated 96%+ · under $12.00")

        let fewReviews = Deal(item: StoreItem(appID: 9, name: "Tiny", capsuleURL: nil, price: nil,
                                              reviews: ReviewSummary(percentPositive: 100, count: 3, label: "")),
                              price: Price(currency: "USD", finalCents: 100, originalCents: 1000, discountPercent: 90),
                              lowestSeenCents: nil, targetCents: nil, isFirstSale: false)
        XCTAssertFalse(rated.matches(fewReviews), "3 reviews isn't a rating")
        XCTAssertTrue(DealRule(minDiscount: 50).matches(fewReviews), "no rating condition: any game counts")
    }

    func testRuleAlertsRankAfterTargetsAndShowInPicks() {
        var policy = DealEngine.Policy()
        policy.rule = DealRule(minDiscount: 30)
        let alerts = DealEngine.alerts(for: deals, alreadySent: [], policy: policy, armed: true)
        let byName = Dictionary(uniqueKeysWithValues: alerts.map { ($0.deal.item.name, $0.kind) })
        XCTAssertEqual(byName["Hollow Knight: Silksong"], .target, "a target hit outranks the rule")
        XCTAssertEqual(byName["Outer Wilds"], .rule)
        XCTAssertEqual(byName["Brotato"], .rule)
        XCTAssertEqual(byName["Satisfactory"], .firstSale, "20% off: not a rule match")
        XCTAssertTrue(alerts.first { $0.deal.item.name == "Outer Wilds" }!.body.contains("96% positive"))
        XCTAssertTrue(DealEngine.alerts(for: deals, alreadySent: [], policy: policy, armed: false).allSatisfy { $0.kind == .target },
                      "rule matches wait for an armed refresh like other non-target alerts")

        XCTAssertEqual(DealEngine.filter(deals, .picks, rule: policy.rule).count, 4)
        XCTAssertTrue(DealEngine.filter(deals, .picks).isEmpty, "no rule, no picks")
        let digest = NotificationPlan.plan(alerts, totalOnSale: 7, event: nil).digest
        XCTAssertTrue(digest?.body.contains("match your rule") ?? false)
    }
}

final class QualityOfLifeTests: XCTestCase {
    override func setUp() { super.setUp(); _ = pinLocale }

    func testQuietHoursWrapMidnight() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: h))! }
        let night = QuietHours(startHour: 22, endHour: 8)
        XCTAssertEqual([21, 22, 23, 0, 7, 8, 12].map { night.contains(at($0), calendar: cal) }, [false, true, true, true, true, false, false])
        let nap = QuietHours(startHour: 13, endHour: 15)
        XCTAssertEqual([12, 13, 14, 15].map { nap.contains(at($0), calendar: cal) }, [false, true, true, false])
        XCTAssertFalse(QuietHours(startHour: 9, endHour: 9).contains(at(9), calendar: cal), "zero-length window is off")
    }

    func testQuickLimitsSkipWhatAlreadyFires() {
        func deal(final: Int, original: Int, low: Int?) -> Deal {
            Deal(item: StoreItem(appID: 1, name: "G", capsuleURL: nil, price: nil),
                 price: Price(currency: "USD", finalCents: final, originalCents: original, discountPercent: (original - final) * 100 / original),
                 lowestSeenCents: low, targetCents: nil, isFirstSale: false)
        }
        let atTwenty = QuickLimit.options(for: deal(final: 1600, original: 2000, low: 1200))
        XCTAssertEqual(atTwenty.map(\.label), ["25% off", "lowest seen", "50% off", "75% off"])
        XCTAssertEqual(atTwenty.map(\.cents), [1500, 1200, 1000, 500])
        let deep = QuickLimit.options(for: deal(final: 800, original: 2000, low: 1000))
        XCTAssertEqual(deep.map(\.label), ["75% off"], "50% and the old low are already beaten by the current price")
        XCTAssertEqual(QuickLimit.options(for: deal(final: 1000, original: 2000, low: 500)).map(\.label), ["75% off"],
                       "75% off ($5.00) equals the old low: listed once")
    }

    func testEndingSoon() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func deal(_ id: AppID, hours: Double?) -> Deal {
            Deal(item: StoreItem(appID: id, name: "\(id)", capsuleURL: nil, price: nil),
                 price: Price(currency: "USD", finalCents: 1, originalCents: 2, discountPercent: 50, saleEnds: hours.map { now.addingTimeInterval($0 * 3600) }),
                 lowestSeenCents: nil, targetCents: nil, isFirstSale: false)
        }
        let ds = [deal(1, hours: 5), deal(2, hours: 30), deal(3, hours: nil), deal(4, hours: -1)]
        XCTAssertEqual(DealEngine.filter(ds, .endingSoon, now: now).map(\.id), [1])
    }
}

final class LocalSteamTests: XCTestCase {
    let sample = """
    "users"
    {
    	"76561197960287930"
    	{
    		"AccountName"		"oldalt"
    		"PersonaName"		"Old \\"Alt\\""
    		"MostRecent"		"0"
    		"Timestamp"		"1600000000"
    	}
    	// a comment Steam doesn't write but parsers should survive
    	"76561198000000001"
    	{
    		"AccountName"		"mainacct"
    		"PersonaName"		"Main"
    		"RememberPassword"		"1"
    		"MostRecent"		"1"
    		"Timestamp"		"1790000000"
    	}
    	"notanid"
    	{
    		"AccountName"		"x"
    	}
    }
    """

    func testParsesAccountsMostRecentFirst() {
        let accounts = LocalSteam.parseLoginUsers(sample)
        XCTAssertEqual(accounts.map(\.steamID), ["76561198000000001", "76561197960287930"])
        XCTAssertEqual(accounts[0].displayName, "Main")
        XCTAssertTrue(accounts[0].mostRecent)
        XCTAssertEqual(accounts[1].personaName, "Old \"Alt\"", "escaped quotes")
        XCTAssertEqual(accounts[1].lastLogin, Date(timeIntervalSince1970: 1_600_000_000))
    }

    func testLowercaseKeysFromNewerClients() {
        let one = #""users" { "76561198000000001" { "AccountName" "a" "PersonaName" "P" "timestamp" "1790000000" "AutoLogin" "1" } }"#
        let a = LocalSteam.parseLoginUsers(one)
        XCTAssertEqual(a.first?.lastLogin, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(a.first?.mostRecent, false, "single-account files omit MostRecent")
    }

    func testToleratesJunkAndMissingFiles() {
        XCTAssertTrue(LocalSteam.parseLoginUsers("").isEmpty)
        XCTAssertTrue(LocalSteam.parseLoginUsers("not vdf at all").isEmpty)
        XCTAssertTrue(LocalSteam.parseLoginUsers(#""users" { "76561198000000001" { "AccountName" "a""#).count == 1, "truncated file")
        XCTAssertTrue(LocalSteam.accounts(paths: [URL(fileURLWithPath: "/nonexistent/loginusers.vdf")]).isEmpty)
    }

    func testReadsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loginusers-\(UUID().uuidString).vdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try sample.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(LocalSteam.accounts(paths: [URL(fileURLWithPath: "/nope"), url]).first?.accountName, "mainacct")
    }
}

final class PriceHistoryTests: XCTestCase {
    override func setUp() { super.setUp(); _ = pinLocale }

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
    override func setUp() { super.setUp(); _ = pinLocale }

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
    override func setUp() { super.setUp(); _ = pinLocale }

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
    override func setUp() { super.setUp(); _ = pinLocale }

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
        let noKey = SteamClient(transport: Stub(status: 200), retryDelays: [])
        do { _ = try await noKey.recentlyPlayed(steamID: "1"); XCTFail() } catch { XCTAssertEqual(error as? SteamError, .missingAPIKey) }
        let badKey = SteamClient(transport: Stub(status: 403), apiKey: "x", retryDelays: [])
        do { _ = try await badKey.recentlyPlayed(steamID: "1"); XCTFail() } catch { XCTAssertEqual(error as? SteamError, .badAPIKey) }
        let limited = SteamClient(transport: Stub(status: 429), retryDelays: [0])
        do { _ = try await limited.wishlist(steamID: "1"); XCTFail() } catch { XCTAssertEqual(error as? SteamError, .rateLimited) }
    }

    /// Answers each request from a scripted list of statuses, in order, and counts calls.
    final class Script: HTTPTransport, @unchecked Sendable {
        var statuses: [Int]
        var calls = 0
        let body: String
        init(_ statuses: [Int], body: String = #"{"response":{"items":[{"appid":1}]}}"#) { self.statuses = statuses; self.body = body }
        func get(_ url: URL) async throws -> (Data, Int) {
            calls += 1
            let s = statuses.isEmpty ? 200 : statuses.removeFirst()
            if s < 0 { throw SteamError.transport("connection dropped") }
            return (Data(body.utf8), s)
        }
    }

    func testRetriesRateLimitsServerErrorsAndDrops() async throws {
        let script = Script([429, 503, -1, 200])
        let client = SteamClient(transport: script, retryDelays: [0, 0, 0])
        let items = try await client.wishlist(steamID: "1")
        XCTAssertEqual(items.map(\.appID), [1])
        XCTAssertEqual(script.calls, 4)

        let exhausted = Script([429, 429, 429])
        do { _ = try await SteamClient(transport: exhausted, retryDelays: [0, 0]).wishlist(steamID: "1"); XCTFail() }
        catch { XCTAssertEqual(error as? SteamError, .rateLimited); XCTAssertEqual(exhausted.calls, 3) }

        let fatal = Script([404])
        do { _ = try await SteamClient(transport: fatal, retryDelays: [0, 0]).wishlist(steamID: "1"); XCTFail() }
        catch { XCTAssertEqual(error as? SteamError, .http(404)); XCTAssertEqual(fatal.calls, 1, "4xx is not retried") }
    }

    func testPartialStoreFetchKeepsGoodBatchesAndStopsAfterRateLimit() async {
        let one = #"{"response":{"store_items":[{"id":1,"success":1,"name":"One"}]}}"#
        // Batch 1 ok, batch 2 a persistent 500, batch 3 ok: two of three batches come back.
        let flaky = Script([200, 500, 500, 200], body: one)
        let r = await SteamClient(transport: flaky, retryDelays: [0]).storeItems(partial: Array(1...150))
        XCTAssertEqual(r.items.count, 2)
        XCTAssertEqual(r.missing, Array(51...100))
        XCTAssertEqual(r.error, .http(500))
        XCTAssertFalse(r.isComplete)

        // A rate limit on batch 1 stops the run: batches 2 and 3 are reported missing untouched.
        let limited = Script([429, 429], body: one)
        let l = await SteamClient(transport: limited, retryDelays: [0]).storeItems(partial: Array(1...150))
        XCTAssertTrue(l.items.isEmpty)
        XCTAssertEqual(l.missing.count, 150)
        XCTAssertEqual(l.error, .rateLimited)
        XCTAssertEqual(limited.calls, 2)
    }
}
