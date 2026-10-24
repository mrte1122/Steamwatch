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
