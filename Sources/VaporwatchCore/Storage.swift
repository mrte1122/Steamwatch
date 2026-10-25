import Foundation

/// One Codable value per JSON file, written atomically. Platforms decide the directory
/// (Application Support on macOS, %LOCALAPPDATA% on Windows); the file formats are shared.
public struct JSONFile<T: Codable> {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(T.self, from: data)
    }

    public func save(_ value: T) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// The last successful reading, so the popover has something to show at launch before the first
/// refresh finishes.
public struct CachedState: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var wishlist: [WishlistEntry]
    public var items: [StoreItem]
    public var recentGames: [RecentGame]
    public var me: PlayerSummary?
    public var friendsOnline: [PlayerSummary]

    public init(fetchedAt: Date, wishlist: [WishlistEntry], items: [StoreItem], recentGames: [RecentGame],
                me: PlayerSummary?, friendsOnline: [PlayerSummary]) {
        self.fetchedAt = fetchedAt; self.wishlist = wishlist; self.items = items
        self.recentGames = recentGames; self.me = me; self.friendsOnline = friendsOnline
    }
}

/// Games the user marked "bought it" (or just doesn't want to see), keyed by appID as a string
/// with the time they were hidden. Entries vanish once the game leaves the wishlist.
public struct HiddenGames: Codable, Equatable, Sendable {
    public var hiddenAt: [String: Date]
    public init(hiddenAt: [String: Date] = [:]) { self.hiddenAt = hiddenAt }

    public var appIDs: Set<AppID> { Set(hiddenAt.keys.compactMap(Int.init)) }
    public var count: Int { hiddenAt.count }

    public mutating func hide(_ appID: AppID, at now: Date = Date()) { hiddenAt[String(appID)] = now }
    public mutating func unhide(_ appID: AppID) { hiddenAt[String(appID)] = nil }
    public mutating func prune(keeping wishlist: Set<AppID>) {
        hiddenAt = hiddenAt.filter { k, _ in Int(k).map(wishlist.contains) ?? false }
    }
}

/// Games watched without being on the Steam wishlist, added through store search. Keyed by appID
/// as a string; the name is kept so Settings can list a game before its first store reading.
public struct Watchlist: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        public var added: Date
        public init(name: String, added: Date) { self.name = name; self.added = added }
    }

    public var entries: [String: Entry]
    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    public var appIDs: Set<AppID> { Set(entries.keys.compactMap(Int.init)) }
    public var count: Int { entries.count }
    public func contains(_ appID: AppID) -> Bool { entries[String(appID)] != nil }
    public func name(_ appID: AppID) -> String? { entries[String(appID)]?.name }

    public mutating func add(_ appID: AppID, name: String, at now: Date = Date()) {
        if entries[String(appID)] == nil { entries[String(appID)] = Entry(name: name, added: now) }
    }
    public mutating func remove(_ appID: AppID) { entries[String(appID)] = nil }

    /// Watched games as wishlist-shaped entries (unranked), so the deal engine treats both alike.
    public func asWishlistEntries(excluding wishlisted: Set<AppID> = []) -> [WishlistEntry] {
        entries.compactMap { key, e in
            guard let id = Int(key), !wishlisted.contains(id) else { return nil }
            return WishlistEntry(appID: id, priority: 0, added: e.added)
        }
    }
}

/// Target prices, keyed by appID as a string.
public struct Targets: Codable, Equatable, Sendable {
    public var cents: [String: Int]
    public init(cents: [String: Int] = [:]) { self.cents = cents }

    public subscript(appID: AppID) -> Int? {
        get { cents[String(appID)] }
        set { cents[String(appID)] = newValue }
    }

    public var byAppID: [AppID: Int] {
        Dictionary(uniqueKeysWithValues: cents.compactMap { k, v in Int(k).map { ($0, v) } })
    }
}
