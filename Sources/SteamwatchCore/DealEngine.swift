import Foundation

/// A notification the platform layer should show. `key` deduplicates: one alert per app per price.
public struct DealAlert: Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case target, rule, newLow, firstSale, sale }

    public let kind: Kind
    public let deal: Deal

    public init(kind: Kind, deal: Deal) { self.kind = kind; self.deal = deal }
    public var id: String { key }
    public var key: String { "\(deal.item.appID)-\(deal.price.finalCents)" }

    public var title: String {
        switch kind {
        case .target: return "\(deal.item.name) hit your target price"
        case .rule: return "\(deal.item.name) matches your deal rule"
        case .newLow: return "\(deal.item.name) is at a new low"
        case .firstSale: return "\(deal.item.name) is on sale for the first time"
        case .sale: return "\(deal.item.name) is on sale"
        }
    }

    public var body: String {
        let price = Format.price(deal.price.finalCents, currency: deal.price.currency)
        // A target hit can come from a permanent price cut, with no discount to show.
        var s = deal.price.discountPercent > 0 ? "\(price) (−\(deal.price.discountPercent)%)" : "\(price), a new regular price"
        if kind == .target || kind == .newLow, deal.isLowestSeen, deal.lowestSeenCents != nil { s += ", the lowest it's been" }
        if kind == .rule, let r = deal.item.reviews { s += " · \(r.percentPositive)% positive" }
        if let ends = deal.price.saleEnds { s += " · ends \(Format.saleEnds(ends))" }
        return s
    }
}

public enum DealEngine {
    /// Pair the wishlist with store data and history. `history` must be the state *before* this
    /// reading was observed, so lows and first sales are judged against the past.
    public static func deals(wishlist: [WishlistEntry], items: [StoreItem], history: PriceHistory,
                             targets: [AppID: Int], hidden: Set<AppID> = []) -> [Deal] {
        let priorities = Dictionary(wishlist.map { ($0.appID, $0.priority) }, uniquingKeysWith: { a, _ in a })
        var deals: [Deal] = []
        for item in items where priorities[item.appID] != nil && !hidden.contains(item.appID) {
            // On sale, or at/under the user's limit through a permanent price cut.
            guard let price = item.price, price.isOnSale || targets[item.appID].map({ price.finalCents <= $0 }) == true else { continue }
            let past = history.record(item.appID)
            deals.append(Deal(item: item, price: price, lowestSeenCents: past?.lowestCents, targetCents: targets[item.appID],
                              isFirstSale: past.map { !$0.seenOnSale } ?? false, priority: priorities[item.appID] ?? 0))
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
        /// A standing "any game at X% off" rule; nil when off.
        public var rule: DealRule?
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
            else if let rule = policy.rule, rule.matches(deal) { kind = .rule }
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

    /// Narrow a (sorted) deal list for the popover; order is preserved.
    public static func filter(_ deals: [Deal], _ filter: DealFilter, query: String = "", rule: DealRule? = nil) -> [Deal] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return deals.filter { d in
            guard filter.matches(d, rule: rule) else { return false }
            return q.isEmpty || d.item.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// The chip row above the deal list.
public enum DealFilter: String, CaseIterable, Codable, Sendable, Identifiable {
    case all, picks, targets, lows, halfOff, underTen, mac, deck

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .picks: return "Picks"
        case .targets: return "Targets"
        case .lows: return "Lows"
        case .halfOff: return "50%+"
        case .underTen: return "Under 10"
        case .mac: return "Mac"
        case .deck: return "Deck"
        }
    }

    /// `.picks` needs the user's rule; without one it matches nothing (and the chip is hidden).
    public func matches(_ d: Deal, rule: DealRule? = nil) -> Bool {
        switch self {
        case .all: return true
        case .picks: return rule?.matches(d) ?? false
        case .targets: return d.targetCents != nil
        case .lows: return d.isFirstSale || d.isNewLow
        case .halfOff: return d.price.discountPercent >= 50
        case .underTen: return d.price.finalCents < 1000
        case .mac: return d.item.platforms?.mac ?? false
        case .deck: return (d.item.platforms?.deck ?? .unknown).rawValue >= Platforms.Deck.playable.rawValue
        }
    }
}

/// "Tell me about any game that's at least this good a deal": a standing rule that covers the
/// whole wishlist (and watched games) without setting a limit on each one.
public struct DealRule: Codable, Equatable, Sendable {
    public var minDiscount: Int
    /// Steam review percentage; nil means any. Games with fewer than `minReviews` reviews don't
    /// count as rated, so a 100% from three people doesn't qualify.
    public var minRating: Int?
    public var maxPriceCents: Int?
    public var minReviews: Int

    public init(minDiscount: Int, minRating: Int? = nil, maxPriceCents: Int? = nil, minReviews: Int = 50) {
        self.minDiscount = minDiscount; self.minRating = minRating; self.maxPriceCents = maxPriceCents; self.minReviews = minReviews
    }

    public func matches(_ d: Deal) -> Bool {
        guard d.price.discountPercent >= minDiscount else { return false }
        if let max = maxPriceCents, d.price.finalCents > max { return false }
        if let min = minRating {
            guard let r = d.item.reviews, r.count >= minReviews, r.percentPositive >= min else { return false }
        }
        return true
    }

    /// "75%+ off · rated 85%+ · under $20.00"
    public func summary(currency: String = "USD") -> String {
        var parts = ["\(minDiscount)%+ off"]
        if let r = minRating { parts.append("rated \(r)%+") }
        if let m = maxPriceCents { parts.append("under \(Format.price(m, currency: currency))") }
        return parts.joined(separator: " · ")
    }
}

/// Orders for the deal list. `.best` is the engine's own ranking (targets, lows, then score).
public enum DealSort: String, CaseIterable, Codable, Sendable, Identifiable {
    case best, rating, discount, price, endingSoon, name

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .best: return "Best match"
        case .rating: return "Highest rated"
        case .discount: return "Biggest discount"
        case .price: return "Cheapest"
        case .endingSoon: return "Ending soonest"
        case .name: return "Name"
        }
    }

    /// Stable: ties keep the engine's order, so "Highest rated" still puts a target hit above
    /// another game with the same score.
    public func apply(_ deals: [Deal]) -> [Deal] {
        guard self != .best else { return deals }
        let indexed = deals.enumerated().map { ($0.offset, $0.element) }
        return indexed.sorted { a, b in
            let (ka, kb) = (key(a.1), key(b.1))
            return ka != kb ? ka < kb : a.0 < b.0
        }.map(\.1)
    }

    private func key(_ d: Deal) -> (Int, Int) {
        switch self {
        case .best: return (0, 0)
        // Weight the percentage by review count a little so 100% from 12 reviews doesn't top the list.
        case .rating:
            guard let r = d.item.reviews else { return (1, 0) }
            let confidence = min(1.0, Double(r.count) / 500)
            return (0, -Int(Double(r.percentPositive) * (0.6 + 0.4 * confidence) * 100))
        case .discount: return (0, -d.price.discountPercent)
        case .price: return (0, d.price.finalCents)
        case .endingSoon: return (d.price.saleEnds == nil ? 1 : 0, Int(d.price.saleEnds?.timeIntervalSince1970 ?? 0))
        case .name: return (0, 0)
        }
    }
}

extension DealSort {
    /// Name sort can't go through the integer key; handled here so `apply` stays simple.
    public func sorted(_ deals: [Deal]) -> [Deal] {
        self == .name
            ? deals.sorted { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending }
            : apply(deals)
    }
}
