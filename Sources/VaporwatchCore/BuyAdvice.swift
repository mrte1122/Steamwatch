import Foundation

/// One of Steam's seasonal sales, as Valve publishes them for developers ahead of time
/// (partner.steamgames.com/doc/marketing/upcoming_events). Sales start and end at 10:00 Pacific.
public struct SteamSale: Codable, Equatable, Sendable {
    public let name: String
    public let start: Date
    public let end: Date

    public init(name: String, start: Date, end: Date) { self.name = name; self.start = start; self.end = end }

    public func isActive(at now: Date) -> Bool { now >= start && now < end }
}

/// The seasonal-sale schedule. A copy ships with the app; `decode` reads a newer one published as
/// `data/sale-calendar.json` in the repository, so new dates don't need an app update.
public struct SaleCalendar: Equatable, Sendable {
    public let sales: [SteamSale]

    public init(sales: [SteamSale]) { self.sales = sales.sorted { $0.start < $1.start } }

    public func current(at now: Date) -> SteamSale? { sales.first { $0.isActive(at: now) } }
    public func next(after now: Date) -> SteamSale? { sales.first { $0.start > now } }

    /// Valve's published dates as of October 2026. Autumn 2027 was still "TBD".
    public static let builtIn = SaleCalendar(sales: [
        sale("Steam Winter Sale", "2026-12-17", "2027-01-04"),
        sale("Steam Spring Sale", "2027-03-18", "2027-03-25"),
        sale("Steam Summer Sale", "2027-06-24", "2027-07-08"),
    ].compactMap { $0 })

    /// `{"sales":[{"name":"Steam Winter Sale","start":"2026-12-17","end":"2027-01-04"}, …]}`
    public static func decode(_ data: Data) -> SaleCalendar? {
        struct File: Decodable { struct S: Decodable { let name: String; let start: String; let end: String }; let sales: [S] }
        guard let f = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        let sales = f.sales.compactMap { sale($0.name, $0.start, $0.end) }
        return sales.isEmpty ? nil : SaleCalendar(sales: sales)
    }

    /// "2026-12-17" → 10:00 in Seattle that day.
    static func sale(_ name: String, _ start: String, _ end: String) -> SteamSale? {
        guard let s = tenAMPacific(start), let e = tenAMPacific(end), e > s else { return nil }
        return SteamSale(name: name, start: s, end: e)
    }

    private static func tenAMPacific(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 10))
    }
}

/// Should you buy this deal now, or wait? Steam-side signals only: your price limit, the lowest
/// price Vaporwatch has seen, and Valve's seasonal sale calendar. `historicalLowCents` is a hook
/// for a longer price history from another source.
public struct Verdict: Equatable, Sendable {
    public enum Kind: String, Sendable { case buy, wait, fair }
    public let kind: Kind
    /// Short, for the row: "lowest since Oct 24", "Winter Sale in 52d".
    public let reason: String

    public var label: String {
        switch kind {
        case .buy: return "Buy"
        case .wait: return "Wait"
        case .fair: return "Fair"
        }
    }
}

public enum BuyAdvisor {
    /// Wait for a seasonal sale only when it's this close; further out, a decent deal now beats it.
    public static let waitWindowDays = 30
    /// Vaporwatch's own lows only count after this much watching; a two-day-old "low" means little.
    public static let minHistoryDays = 14

    /// - Parameters:
    ///   - watchingSince: when Vaporwatch first saw this game's price.
    ///   - lowestAt: when the earlier low (`deal.lowestSeenCents`) was recorded.
    public static func verdict(for deal: Deal, now: Date = Date(), calendar: SaleCalendar = .builtIn,
                               watchingSince: Date? = nil, lowestAt: Date? = nil,
                               historicalLowCents: Int? = nil, timeZone: TimeZone = .current) -> Verdict {
        let price = deal.price.finalCents
        let cur = deal.price.currency
        func short(_ d: Date) -> String {
            let f = DateFormatter(); f.timeZone = timeZone; f.locale = Format.locale; f.setLocalizedDateFormatFromTemplate("MMMd")
            return f.string(from: d)
        }

        if deal.meetsTarget { return Verdict(kind: .buy, reason: "at your limit") }

        // A longer history (if one is plugged in) wins; otherwise our own, once it's old enough.
        let historyDays = watchingSince.map { now.timeIntervalSince($0) / 86_400 } ?? 0
        let low: Int?
        let lowLabel: String
        if let h = historicalLowCents {
            low = h; lowLabel = "lowest ever"
        } else if historyDays >= Double(minHistoryDays), let own = deal.lowestSeenCents {
            low = own; lowLabel = watchingSince.map { "lowest since \(short($0))" } ?? "lowest seen"
        } else {
            low = nil; lowLabel = ""
        }

        if deal.isNewLow, historyDays >= Double(minHistoryDays) || historicalLowCents != nil {
            return Verdict(kind: .buy, reason: historicalLowCents != nil ? "lowest ever" : "new low")
        }
        if let low, price <= low { return Verdict(kind: .buy, reason: lowLabel) }

        // A seasonal sale is on now: this is probably the price for a while.
        if let sale = calendar.current(at: now) {
            if let low { return Verdict(kind: .fair, reason: "\(sale.name.replacingOccurrences(of: "Steam ", with: "")) price; low \(Format.price(low, currency: cur))") }
            return Verdict(kind: .buy, reason: sale.name.replacingOccurrences(of: "Steam ", with: ""))
        }

        // A seasonal sale is coming soon and this discount ends before it: usually worth waiting.
        if let next = calendar.next(after: now) {
            let days = Int(ceil(next.start.timeIntervalSince(now) / 86_400))
            let endsBefore = deal.price.saleEnds.map { $0 <= next.start } ?? true
            if days <= waitWindowDays, endsBefore {
                return Verdict(kind: .wait, reason: "\(next.name.replacingOccurrences(of: "Steam ", with: "")) in \(days)d")
            }
        }

        if let low {
            // Clearly above a price it has had: say what and when.
            if Double(price) > Double(low) * 1.15 {
                let when = lowestAt.map { " (\(short($0)))" } ?? ""
                return Verdict(kind: .wait, reason: "was \(Format.price(low, currency: cur))\(when)")
            }
            return Verdict(kind: .fair, reason: "near its low")
        }
        // Not enough history to judge: a big discount is the best signal there is.
        return deal.price.discountPercent >= 50 ? Verdict(kind: .fair, reason: "−\(deal.price.discountPercent)%")
                                                : Verdict(kind: .fair, reason: "no history yet")
    }
}

/// Paid games temporarily free to keep (a 100% discount), as opposed to free-to-play.
public enum FreeToKeep {
    /// Keep giveaways people would actually want: a real price, decently reviewed.
    public static func filter(_ items: [StoreItem], minRating: Int = 70, minReviews: Int = 100) -> [StoreItem] {
        items.filter { item in
            guard let p = item.price, p.finalCents == 0, p.originalCents > 0, p.discountPercent >= 99 else { return false }
            guard let r = item.reviews else { return false }
            return r.count >= minReviews && r.percentPositive >= minRating
        }
        .sorted { ($0.reviews?.percentPositive ?? 0, $0.reviews?.count ?? 0) > ($1.reviews?.percentPositive ?? 0, $1.reviews?.count ?? 0) }
    }
}
