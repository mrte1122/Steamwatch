import Foundation

/// A notification the platform layer should show. `key` deduplicates: one alert per app per price.
public struct DealAlert: Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case target, newLow, firstSale, sale }

    public let kind: Kind
    public let deal: Deal
    public var id: String { key }
    public var key: String { "\(deal.item.appID)-\(deal.price.finalCents)" }

    public var title: String {
        switch kind {
        case .target: return "\(deal.item.name) hit your target price"
        case .newLow: return "\(deal.item.name) is at a new low"
        case .firstSale: return "\(deal.item.name) is on sale for the first time"
        case .sale: return "\(deal.item.name) is on sale"
        }
    }

    public var body: String {
        let price = Format.price(deal.price.finalCents, currency: deal.price.currency)
        var s = "\(price) (−\(deal.price.discountPercent)%)"
        if kind == .target || kind == .newLow, deal.isLowestSeen, deal.lowestSeenCents != nil { s += ", the lowest it's been" }
        if let ends = deal.price.saleEnds { s += " · ends \(Format.saleEnds(ends))" }
        return s
    }
}

public enum DealEngine {
    /// Pair the wishlist with store data and history. `history` must be the state *before* this
    /// reading was observed, so lows and first sales are judged against the past.
    public static func deals(wishlist: [WishlistEntry], items: [StoreItem], history: PriceHistory,
                             targets: [AppID: Int]) -> [Deal] {
        let wanted = Set(wishlist.map(\.appID))
        var deals: [Deal] = []
        for item in items where wanted.contains(item.appID) {
            guard let price = item.price, price.isOnSale else { continue }
            let past = history.record(item.appID)
            deals.append(Deal(item: item, price: price, lowestSeenCents: past?.lowestCents, targetCents: targets[item.appID],
                              isFirstSale: past.map { !$0.seenOnSale } ?? false))
        }
        return deals.sorted { a, b in
            a.rank != b.rank ? a.rank < b.rank : a.item.name.localizedCaseInsensitiveCompare(b.item.name) == .orderedAscending
        }
    }

    public struct Policy: Equatable, Sendable {
        public var target = true
        public var newLow = true
        public var firstSale = true
        public var anySale = false
        public init() {}
        public init(target: Bool, newLow: Bool, firstSale: Bool, anySale: Bool) {
            self.target = target; self.newLow = newLow; self.firstSale = firstSale; self.anySale = anySale
        }
    }

    /// Which deals deserve a notification. `armed` is false for the first reading after launch: sales
    /// that started while the app was closed stay quiet, except target hits, which are always news.
    /// Callers record the returned keys plus `keys(for:)` of everything else, so a sale is announced
    /// at most once per price.
    public static func alerts(for deals: [Deal], alreadySent: Set<String>, policy: Policy, armed: Bool) -> [DealAlert] {
        deals.compactMap { deal in
            let kind: DealAlert.Kind
            if deal.meetsTarget, policy.target { kind = .target }
            else if deal.isFirstSale, policy.firstSale { kind = .firstSale }
            else if deal.isNewLow, policy.newLow { kind = .newLow }
            else if policy.anySale { kind = .sale }
            else { return nil }
            guard armed || kind == .target else { return nil }
            let alert = DealAlert(kind: kind, deal: deal)
            return alreadySent.contains(alert.key) ? nil : alert
        }
    }

    public static func keys(for deals: [Deal]) -> Set<String> {
        Set(deals.map { "\($0.item.appID)-\($0.price.finalCents)" })
    }
}
