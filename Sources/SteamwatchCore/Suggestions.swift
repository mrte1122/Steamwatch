import Foundation

/// What the wishlist says about taste: store tags weighted by how often, and how prominently,
/// they appear on wishlisted games. Generic tags ("Indie", "Singleplayer") say little and are left out.
public struct TasteProfile: Equatable, Sendable {
    public let weights: [Int: Double]

    /// Tags too broad to steer suggestions. IDs from IStoreService/GetTagList.
    public static let generic: Set<Int> = [492, 4182, 19, 21, 597, 493, 1756, 3859, 3871, 4191, 4166, 4305, 4726, 113,
                                           4136, 5350, 7481, 4252, 5411, 1693, 4711, 3839, 1697, 1775, 6730]

    public init(weights: [Int: Double]) { self.weights = weights }

    /// Each game's tags count less the further down its list they are; games ranked in the user's
    /// top 30 count double.
    public static func build(from items: [StoreItem], priorities: [AppID: Int] = [:]) -> TasteProfile {
        var w: [Int: Double] = [:]
        for item in items {
            let boost = (priorities[item.appID].map { $0 > 0 && $0 <= 30 } ?? false) ? 2.0 : 1.0
            for (i, tag) in (item.tagIDs ?? []).prefix(8).enumerated() where !generic.contains(tag) {
                w[tag, default: 0] += boost * (1.0 - Double(i) * 0.1)
            }
        }
        return TasteProfile(weights: w)
    }

    /// The strongest tags, for the store query.
    public func top(_ n: Int) -> [Int] {
        weights.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(n).map(\.key)
    }

    public var isEmpty: Bool { weights.isEmpty }
}

/// A game Steamwatch thinks the user would like, with the tags that made the match.
public struct Suggestion: Codable, Equatable, Sendable, Identifiable {
    public let item: StoreItem
    public let matchedTags: [Int]
    public let score: Double
    public var id: AppID { item.appID }

    public init(item: StoreItem, matchedTags: [Int], score: Double) {
        self.item = item; self.matchedTags = matchedTags; self.score = score
    }
}

public enum SuggestionEngine {
    /// Rank store candidates against the profile. Excludes anything in `exclude` (wishlisted,
    /// watched, owned, dismissed), games without a discount or a price, and ones without a solid
    /// rating: at least `minRating`% positive from `minReviews` reviews.
    public static func rank(_ candidates: [StoreItem], profile: TasteProfile, exclude: Set<AppID>,
                            minRating: Int = 85, minReviews: Int = 500, limit: Int = 10) -> [Suggestion] {
        guard let maxWeight = profile.weights.values.max(), maxWeight > 0 else { return [] }
        var seen = Set<AppID>()
        var out: [Suggestion] = []
        for item in candidates where !exclude.contains(item.appID) && seen.insert(item.appID).inserted {
            guard let price = item.price, price.isOnSale,
                  let r = item.reviews, r.count >= minReviews, r.percentPositive >= minRating else { continue }
            let tags = (item.tagIDs ?? []).prefix(8)
            var fit = 0.0
            var matched: [(Int, Double)] = []
            for (i, tag) in tags.enumerated() {
                guard let w = profile.weights[tag] else { continue }
                let part = (w / maxWeight) * (1.0 - Double(i) * 0.1)
                fit += part
                matched.append((tag, part))
            }
            guard fit > 0 else { continue }
            // Fit dominates; quality and discount break ties between similar fits.
            let confidence = min(1.0, Double(r.count) / 2000)
            let quality = Double(r.percentPositive) / 100 * (0.7 + 0.3 * confidence)
            let score = fit * quality + Double(price.discountPercent) / 400
            out.append(Suggestion(item: item, matchedTags: matched.sorted { $0.1 > $1.1 }.prefix(2).map(\.0), score: score))
        }
        return Array(out.sorted { $0.score != $1.score ? $0.score > $1.score : $0.item.appID < $1.item.appID }.prefix(limit))
    }
}

/// Suggestions as last fetched, so the popover has them at launch.
public struct SuggestionsCache: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var suggestions: [Suggestion]
    /// Names for the tags in `matchedTags`, so they can be shown without another fetch.
    public var tagNames: [String: String]

    public init(fetchedAt: Date, suggestions: [Suggestion], tagNames: [String: String]) {
        self.fetchedAt = fetchedAt; self.suggestions = suggestions; self.tagNames = tagNames
    }

    public func names(for s: Suggestion) -> [String] { s.matchedTags.compactMap { tagNames[String($0)] } }
}
