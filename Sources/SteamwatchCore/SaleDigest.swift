import Foundation

/// A storewide sale (Autumn, Winter, Summer…) as seen from one wishlist. Steam's API doesn't name
/// sales (discount descriptions are localization tokens like `#discount_desc_preset_special`), so
/// an event is inferred from what changes: many wishlisted games going on sale at once.
public struct SaleEvent: Codable, Equatable, Sendable {
    public var started: Date
    /// Wishlist games that were already discounted when the event began.
    public var baselineCount: Int
    /// When most of the event's discounts end, if they cluster.
    public var ends: Date?

    public init(started: Date, baselineCount: Int, ends: Date?) {
        self.started = started; self.baselineCount = baselineCount; self.ends = ends
    }

    /// How many more games are discounted than before the event.
    public func extra(_ deals: [Deal]) -> Int { max(0, deals.count - baselineCount) }

    /// New discounts in one refresh that count as a sale starting: 1 in 20 wishlist games, at least 8.
    public static func threshold(wishlistCount: Int) -> Int { max(8, wishlistCount / 20) }

    /// Start, continue or end an event from one refresh. `previousIDs` are the apps discounted in
    /// the reading before this one; empty means there was none (first run), which never starts an
    /// event because everything would look new.
    public static func evaluate(_ current: SaleEvent?, previousIDs: Set<AppID>, deals: [Deal],
                                wishlistCount: Int, now: Date = Date()) -> SaleEvent? {
        let threshold = threshold(wishlistCount: wishlistCount)
        if var event = current {
            // Over once the deal count falls back near where it started, or the clustered end passes.
            if deals.count <= event.baselineCount + threshold / 2 { return nil }
            if let ends = event.ends, ends < now { return nil }
            if let ends = commonEnd(of: deals, minimum: threshold / 2, now: now) { event.ends = ends }
            return event
        }
        guard !previousIDs.isEmpty else { return nil }
        let newDeals = deals.filter { !previousIDs.contains($0.item.appID) }
        guard newDeals.count >= threshold else { return nil }
        return SaleEvent(started: now, baselineCount: deals.count - newDeals.count,
                         ends: commonEnd(of: newDeals, minimum: threshold / 2, now: now))
    }

    /// The latest end time on the calendar day (UTC) that the most discounts end on, when at least
    /// `minimum` share it. Publishers set slightly different hours, so days, not instants, are grouped.
    static func commonEnd(of deals: [Deal], minimum: Int, now: Date) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let ends = deals.compactMap(\.price.saleEnds).filter { $0 > now }
        let byDay = Dictionary(grouping: ends) { utc.startOfDay(for: $0) }
        guard let best = byDay.max(by: { $0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key > $1.key) }),
              best.value.count >= max(1, minimum) else { return nil }
        return best.value.max()
    }
}

/// One notification standing in for many, so a storewide sale doesn't post dozens of banners.
public struct DealDigest: Equatable, Sendable {
    public let alerts: [DealAlert]
    public let totalOnSale: Int
    public let event: SaleEvent?

    public var title: String {
        if event != nil { return "Steam sale: \(totalOnSale) wishlist games on sale" }
        return "\(alerts.count) wishlist games dropped in price"
    }

    public var body: String {
        var parts: [String] = []
        let count = { (k: DealAlert.Kind) in self.alerts.filter { $0.kind == k }.count }
        if count(.target) > 0 { parts.append("\(count(.target)) under target") }
        if count(.firstSale) > 0 { parts.append("\(count(.firstSale)) first sales") }
        if count(.newLow) > 0 { parts.append("\(count(.newLow)) new lows") }
        if count(.sale) > 0, parts.isEmpty { parts.append("\(count(.sale)) on sale") }
        if let ends = event?.ends { parts.append("most end \(Format.saleEnds(ends))") }
        let top = alerts.prefix(2).map { "\($0.deal.item.name) −\($0.deal.price.discountPercent)%" }
        return parts.joined(separator: " · ") + (top.isEmpty ? "" : "\n" + top.joined(separator: ", "))
    }
}

public enum NotificationPlan {
    /// Split a refresh's alerts into individual notifications and at most one digest.
    /// Target hits are what the user explicitly asked for, so up to `maxTargets` of them always post
    /// on their own. Everything else is posted individually only when there are fewer than
    /// `digestAt` of them and no sale event is running; otherwise it's folded into a digest.
    public static func plan(_ alerts: [DealAlert], totalOnSale: Int, event: SaleEvent?,
                            maxTargets: Int = 3, digestAt: Int = 4) -> (individual: [DealAlert], digest: DealDigest?) {
        let targets = alerts.filter { $0.kind == .target }
        let individualTargets = Array(targets.prefix(maxTargets))
        let shownKeys = Set(individualTargets.map(\.key))
        let rest = alerts.filter { !shownKeys.contains($0.key) }
        if rest.isEmpty { return (individualTargets, nil) }
        if event == nil, rest.count < digestAt { return (individualTargets + rest, nil) }
        return (individualTargets, DealDigest(alerts: rest, totalOnSale: totalOnSale, event: event))
    }
}
