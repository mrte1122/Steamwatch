import Foundation

public typealias AppID = Int

/// One entry of a Steam wishlist (IWishlistService/GetWishlist).
public struct WishlistEntry: Codable, Equatable, Sendable {
    public let appID: AppID
    public let priority: Int
    public let added: Date

    public init(appID: AppID, priority: Int, added: Date) {
        self.appID = appID; self.priority = priority; self.added = added
    }
}

/// The store's current offer for an app. Prices are in minor units (cents) to keep math exact.
public struct Price: Codable, Equatable, Sendable {
    public var currency: String
    public var finalCents: Int
    public var originalCents: Int
    public var discountPercent: Int
    public var saleEnds: Date?

    public init(currency: String, finalCents: Int, originalCents: Int, discountPercent: Int, saleEnds: Date? = nil) {
        self.currency = currency; self.finalCents = finalCents; self.originalCents = originalCents
        self.discountPercent = discountPercent; self.saleEnds = saleEnds
    }

    public var isOnSale: Bool { discountPercent > 0 && finalCents < originalCents }
}

/// A store listing: name, art and price. Unreleased or delisted apps have no price.
public struct StoreItem: Codable, Equatable, Sendable, Identifiable {
    public let appID: AppID
    public let name: String
    public let capsuleURL: URL?
    public let price: Price?
    public let isFree: Bool

    public init(appID: AppID, name: String, capsuleURL: URL?, price: Price?, isFree: Bool = false) {
        self.appID = appID; self.name = name; self.capsuleURL = capsuleURL; self.price = price; self.isFree = isFree
    }

    public var id: AppID { appID }
    public var storeURL: URL { URL(string: "https://store.steampowered.com/app/\(appID)/")! }
}

/// A wishlisted game that is on sale right now, with the context that decides how loudly to show it.
public struct Deal: Identifiable, Equatable, Sendable {
    public let item: StoreItem
    public let price: Price
    /// Lowest price seen before this reading, if the app has been watched before.
    public let lowestSeenCents: Int?
    /// The user's "tell me when it drops to" price.
    public let targetCents: Int?
    /// True when no earlier reading ever showed this app discounted.
    public let isFirstSale: Bool

    public init(item: StoreItem, price: Price, lowestSeenCents: Int?, targetCents: Int?, isFirstSale: Bool) {
        self.item = item; self.price = price; self.lowestSeenCents = lowestSeenCents
        self.targetCents = targetCents; self.isFirstSale = isFirstSale
    }

    public var id: AppID { item.appID }
    public var meetsTarget: Bool { targetCents.map { price.finalCents <= $0 } ?? false }
    public var isLowestSeen: Bool { lowestSeenCents.map { price.finalCents <= $0 } ?? true }
    /// "Lowest seen" only means something once there's history to compare against.
    public var isNewLow: Bool { lowestSeenCents.map { price.finalCents < $0 } ?? false }

    /// Lower sorts first: target hits, first sales (which are always new lows too, and the more
    /// useful label), other new lows, then by discount.
    public var rank: (Int, Int) {
        let tier = meetsTarget ? 0 : isFirstSale ? 1 : isNewLow ? 2 : 3
        return (tier, -price.discountPercent)
    }
}

/// From IPlayerService/GetRecentlyPlayedGames: minutes over the trailing two weeks and all time.
public struct RecentGame: Codable, Equatable, Sendable, Identifiable {
    public let appID: AppID
    public let name: String
    public let minutesTwoWeeks: Int
    public let minutesForever: Int
    public let iconURL: URL?

    public init(appID: AppID, name: String, minutesTwoWeeks: Int, minutesForever: Int, iconURL: URL? = nil) {
        self.appID = appID; self.name = name; self.minutesTwoWeeks = minutesTwoWeeks
        self.minutesForever = minutesForever; self.iconURL = iconURL
    }

    public var id: AppID { appID }
}

/// From ISteamUser/GetPlayerSummaries, for the signed-in user and for friends.
public struct PlayerSummary: Codable, Equatable, Sendable, Identifiable {
    public let steamID: String
    public let name: String
    public let avatarURL: URL?
    public let isOnline: Bool
    public let currentGame: String?
    public let currentGameID: AppID?

    public init(steamID: String, name: String, avatarURL: URL?, isOnline: Bool, currentGame: String?, currentGameID: AppID?) {
        self.steamID = steamID; self.name = name; self.avatarURL = avatarURL; self.isOnline = isOnline
        self.currentGame = currentGame; self.currentGameID = currentGameID
    }

    public var id: String { steamID }
    public var profileURL: URL { URL(string: "https://steamcommunity.com/profiles/\(steamID)/")! }
}
