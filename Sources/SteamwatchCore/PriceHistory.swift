import Foundation

/// What the app has seen each wishlisted game sell for. Steam has no price-history API, so lows
/// are only as old as the first time Steamwatch looked. Keyed by appID as a string so the JSON
/// is a plain object (JSONEncoder turns Int-keyed dictionaries into arrays).
public struct PriceHistory: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var currency: String
        public var lowestCents: Int
        public var lowestAt: Date
        public var lastCents: Int
        public var lastSeen: Date
        public var firstSeen: Date
        /// Has any reading ever shown a discount.
        public var seenOnSale: Bool

        public init(currency: String, lowestCents: Int, lowestAt: Date, lastCents: Int, lastSeen: Date, firstSeen: Date, seenOnSale: Bool) {
            self.currency = currency; self.lowestCents = lowestCents; self.lowestAt = lowestAt; self.lastCents = lastCents
            self.lastSeen = lastSeen; self.firstSeen = firstSeen; self.seenOnSale = seenOnSale
        }
    }

    public var records: [String: Record]

    public init(records: [String: Record] = [:]) { self.records = records }

    public func record(_ appID: AppID) -> Record? { records[String(appID)] }

    /// Fold one store reading in. Returns the record as it was *before* this reading, which is
    /// what "new low" and "first sale" compare against.
    @discardableResult
    public mutating func observe(_ item: StoreItem, at now: Date = Date()) -> Record? {
        guard let p = item.price else { return record(item.appID) }
        let key = String(item.appID)
        let before = records[key]
        if var r = before, r.currency == p.currency {
            if p.finalCents < r.lowestCents { r.lowestCents = p.finalCents; r.lowestAt = now }
            r.lastCents = p.finalCents
            r.lastSeen = now
            r.seenOnSale = r.seenOnSale || p.isOnSale
            records[key] = r
        } else {
            records[key] = Record(currency: p.currency, lowestCents: p.finalCents, lowestAt: now, lastCents: p.finalCents,
                                  lastSeen: now, firstSeen: now, seenOnSale: p.isOnSale)
        }
        return before
    }

    /// Drop apps that left the wishlist long ago so the file doesn't grow forever.
    public mutating func prune(keeping ids: Set<AppID>, olderThan days: Int = 90, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        records = records.filter { key, r in
            if let id = Int(key), ids.contains(id) { return true }
            return r.lastSeen > cutoff
        }
    }
}
