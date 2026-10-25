import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SteamError: Error, LocalizedError, Equatable {
    case http(Int)
    case rateLimited
    case badAPIKey
    case missingAPIKey
    case privateProfile
    case vanityNotFound
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "Steam returned HTTP \(code)."
        case .rateLimited: return "Steam's rate limit was hit; try again in a few minutes."
        case .badAPIKey: return "Steam rejected the API key."
        case .missingAPIKey: return "This needs a Steam Web API key."
        case .privateProfile: return "The profile or its game details are private."
        case .vanityNotFound: return "No Steam profile has that custom URL."
        case .decoding(let m): return "Unexpected response from Steam (\(m))."
        case .transport(let m): return m
        }
    }
}

/// Swappable network layer so the client is testable and portable (URLSession on every platform
/// Swift supports; a Windows port could hand it WinHTTP instead).
public protocol HTTPTransport: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func get(_ url: URL) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Steamwatch/\(SteamClient.version) (menu bar wishlist watcher)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? -1)
        } catch {
            throw SteamError.transport(error.localizedDescription)
        }
    }
}

/// Thin client over the three Steam surfaces the app uses:
///  - IWishlistService and IStoreBrowseService (no key; public profiles only)
///  - IPlayerService / ISteamUser (need the user's Web API key)
public struct SteamClient: Sendable {
    /// The app's version, for the User-Agent and diagnostics. The core can't read a bundle (it has
    /// to build on Linux and Windows too), so each app sets this at launch.
    public static var version = "dev"
    public static let api = URL(string: "https://api.steampowered.com")!
    public static let store = URL(string: "https://store.steampowered.com")!
    public static let assetBase = "https://shared.akamai.steamstatic.com/store_item_assets/"

    public var transport: HTTPTransport
    public var apiKey: String?
    public var countryCode: String
    public var language: String
    /// Waits before each retry of a rate-limited, 5xx or transport-failed request; empty disables retries.
    public var retryDelays: [TimeInterval]

    public init(transport: HTTPTransport = URLSessionTransport(), apiKey: String? = nil,
                countryCode: String = "US", language: String = "english", retryDelays: [TimeInterval] = [2, 6]) {
        self.transport = transport; self.apiKey = apiKey; self.countryCode = countryCode; self.language = language
        self.retryDelays = retryDelays
    }

    /// What `storeItems(partial:)` could and couldn't fetch.
    public struct StoreResult: Sendable {
        public var items: [StoreItem]
        /// App IDs whose batch failed even after retries.
        public var missing: [AppID]
        public var error: SteamError?
        public var isComplete: Bool { missing.isEmpty }
        public init(items: [StoreItem] = [], missing: [AppID] = [], error: SteamError? = nil) {
            self.items = items; self.missing = missing; self.error = error
        }
    }

    // MARK: Wishlist and store (no key)

    /// Empty for a private wishlist too: Steam answers `{"response":{}}` either way.
    public func wishlist(steamID: String) async throws -> [WishlistEntry] {
        struct R: Decodable { struct Item: Decodable { let appid: Int; let priority: Int?; let date_added: Double? }
                              struct Resp: Decodable { let items: [Item]? }; let response: Resp }
        let r: R = try await get("IWishlistService/GetWishlist/v1/", [("steamid", steamID)], keyed: false)
        return (r.response.items ?? []).map {
            WishlistEntry(appID: $0.appid, priority: $0.priority ?? 0, added: Date(timeIntervalSince1970: $0.date_added ?? 0))
        }
    }

    /// Names, capsule art and the best current price for many apps at once (50 per request).
    /// Throws on the first batch that fails after retries; see `storeItems(partial:)` to keep going.
    public func storeItems(_ ids: [AppID]) async throws -> [StoreItem] {
        let r = await storeItems(partial: ids)
        if let e = r.error { throw e }
        return r.items
    }

    /// Like `storeItems`, but a failed batch is skipped and reported instead of aborting the rest,
    /// so a rate limit on batch 12 of 16 still yields 15 batches. After a rate limit the remaining
    /// batches aren't attempted: hammering on would only lengthen the ban.
    public func storeItems(partial ids: [AppID]) async -> StoreResult {
        var result = StoreResult(items: [], missing: [], error: nil)
        var rateLimited = false
        for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            if rateLimited { result.missing += chunk; continue }
            do {
                let input: [String: Any] = [
                    "ids": chunk.map { ["appid": $0] },
                    "context": ["language": language, "country_code": countryCode],
                    "data_request": ["include_assets": true, "include_release": true, "include_reviews": true, "include_platforms": true,
                                     "include_tag_count": 8],
                ]
                let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
                let r: GetItemsResponse = try await get("IStoreBrowseService/GetItems/v1/", [("input_json", json)], keyed: false)
                result.items += (r.response.store_items ?? []).compactMap { StoreItem(wire: $0) }
            } catch {
                result.missing += chunk
                result.error = error as? SteamError ?? .transport(error.localizedDescription)
                if result.error == .rateLimited { rateLimited = true }
            }
        }
        return result
    }

    /// Store search by name, for watching games that aren't on the wishlist. Returns apps only
    /// (games, DLC, soundtracks), in Steam's relevance order. No key needed.
    public func search(_ term: String) async throws -> [StoreItem] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let r: StoreSearchResponse = try await get("api/storesearch/", [("term", q), ("l", language), ("cc", countryCode)],
                                                    keyed: false, base: Self.store)
        return (r.items ?? []).compactMap { StoreItem(search: $0) }
    }

    /// Discounted, released games carrying any of `tagIDs`, in Steam's relevance order: the raw
    /// material for suggestions. No key needed.
    public func discountedGames(withAnyTag tagIDs: [Int], minDiscount: Int = 30, count: Int = 100) async throws -> [StoreItem] {
        guard !tagIDs.isEmpty else { return [] }
        let input: [String: Any] = [
            "query": ["start": 0, "count": count, "sort": 11,
                      "filters": ["released_only": true, "type_filters": ["include_games": true],
                                  "tagids_must_match": [["tagids": tagIDs]],
                                  "price_filters": ["min_discount_percent": minDiscount]]],
            "context": ["language": language, "country_code": countryCode],
            "data_request": ["include_assets": true, "include_reviews": true, "include_platforms": true, "include_tag_count": 8],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let r: GetItemsResponse = try await get("IStoreQueryService/Query/v1/", [("input_json", json)], keyed: false)
        return (r.response.store_items ?? []).compactMap { StoreItem(wire: $0) }
    }

    /// Tag names by ID, for explaining suggestions ("Roguelike, Deckbuilding").
    public func tagNames() async throws -> [Int: String] {
        struct R: Decodable { struct T: Decodable { let tagid: Int; let name: String }; struct Resp: Decodable { let tags: [T]? }; let response: Resp }
        let r: R = try await get("IStoreService/GetTagList/v1/", [("language", language)], keyed: false)
        return Dictionary((r.response.tags ?? []).map { ($0.tagid, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Player (key required)

    /// Every game the account owns (free ones it has played included), so suggestions skip them.
    public func ownedGames(steamID: String) async throws -> Set<AppID> {
        struct R: Decodable { struct G: Decodable { let appid: Int }; struct Resp: Decodable { let games: [G]? }; let response: Resp }
        let r: R = try await get("IPlayerService/GetOwnedGames/v1/", [("steamid", steamID), ("include_played_free_games", "1")], keyed: true)
        return Set((r.response.games ?? []).map(\.appid))
    }

    public func resolveVanity(_ name: String) async throws -> String {
        struct R: Decodable { struct Resp: Decodable { let success: Int; let steamid: String? }; let response: Resp }
        let r: R = try await get("ISteamUser/ResolveVanityURL/v1/", [("vanityurl", name)], keyed: true)
        guard r.response.success == 1, let id = r.response.steamid else { throw SteamError.vanityNotFound }
        return id
    }

    public func resolve(_ ref: SteamProfileRef) async throws -> String {
        switch ref {
        case .id64(let id): return id
        case .vanity(let name): return try await resolveVanity(name)
        }
    }

    public func recentlyPlayed(steamID: String) async throws -> [RecentGame] {
        struct R: Decodable {
            struct Game: Decodable { let appid: Int; let name: String?; let playtime_2weeks: Int?; let playtime_forever: Int?; let img_icon_url: String? }
            struct Resp: Decodable { let games: [Game]? }
            let response: Resp
        }
        let r: R = try await get("IPlayerService/GetRecentlyPlayedGames/v1/", [("steamid", steamID)], keyed: true)
        return (r.response.games ?? []).map { g in
            let icon = g.img_icon_url.flatMap { $0.isEmpty ? nil : URL(string: "https://media.steampowered.com/steamcommunity/public/images/apps/\(g.appid)/\($0).jpg") }
            return RecentGame(appID: g.appid, name: g.name ?? "App \(g.appid)", minutesTwoWeeks: g.playtime_2weeks ?? 0,
                              minutesForever: g.playtime_forever ?? 0, iconURL: icon)
        }
    }

    public func playerSummaries(_ ids: [String]) async throws -> [PlayerSummary] {
        struct R: Decodable {
            struct P: Decodable { let steamid: String; let personaname: String; let avatarmedium: String?
                                  let personastate: Int?; let gameextrainfo: String?; let gameid: String? }
            struct Resp: Decodable { let players: [P] }
            let response: Resp
        }
        var out: [PlayerSummary] = []
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            let r: R = try await get("ISteamUser/GetPlayerSummaries/v2/", [("steamids", chunk.joined(separator: ","))], keyed: true)
            out += r.response.players.map {
                PlayerSummary(steamID: $0.steamid, name: $0.personaname, avatarURL: $0.avatarmedium.flatMap(URL.init(string:)),
                              isOnline: ($0.personastate ?? 0) != 0, currentGame: $0.gameextrainfo, currentGameID: $0.gameid.flatMap(Int.init))
            }
        }
        return out
    }

    public func friendIDs(steamID: String) async throws -> [String] {
        struct R: Decodable { struct F: Decodable { let steamid: String }
                              struct L: Decodable { let friends: [F] }
                              struct Resp: Decodable { let friendslist: L? }; let friendslist: L? }
        // Steam wraps this one differently from the IPlayerService calls: {"friendslist":{"friends":[…]}}.
        let r: R = try await get("ISteamUser/GetFriendList/v1/", [("steamid", steamID), ("relationship", "friend")], keyed: true)
        return (r.friendslist?.friends ?? []).map(\.steamid)
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, _ query: [(String, String)], keyed: Bool, base: URL = SteamClient.api) async throws -> T {
        var items = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        if keyed {
            guard let apiKey, !apiKey.isEmpty else { throw SteamError.missingAPIKey }
            items.append(URLQueryItem(name: "key", value: apiKey))
        }
        items.append(URLQueryItem(name: "format", value: "json"))
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = items
        let url = comps.url!

        // Retry only what might clear on its own: rate limits, server errors, dropped connections.
        // Bad keys, private profiles and malformed answers come back at once.
        var attempt = 0
        while true {
            let outcome: Result<(Data, Int), SteamError>
            do { outcome = .success(try await transport.get(url)) }
            catch { outcome = .failure(error as? SteamError ?? .transport(error.localizedDescription)) }

            let failure: SteamError
            switch outcome {
            case .success((let data, let status)):
                switch status {
                case 200..<300:
                    do { return try JSONDecoder().decode(T.self, from: data) }
                    catch { throw SteamError.decoding(String(describing: error).prefix(120).description) }
                case 401 where keyed, 403 where keyed: throw SteamError.badAPIKey
                case 401, 403: throw SteamError.privateProfile
                case 429: failure = .rateLimited
                case 500...599: failure = .http(status)
                default: throw SteamError.http(status)
                }
            case .failure(let e):
                failure = e
            }
            guard attempt < retryDelays.count else { throw failure }
            let delay = retryDelays[attempt]
            attempt += 1
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
    }
}

// MARK: - Store search wire format

struct StoreSearchResponse: Decodable {
    struct Item: Decodable {
        struct P: Decodable { let currency: String?; let initial: Int?; let final: Int? }
        let type: String?
        let id: Int
        let name: String
        let price: P?
        let tiny_image: String?
    }
    let items: [Item]?
}

extension StoreItem {
    init?(search i: StoreSearchResponse.Item) {
        guard i.type == nil || i.type == "app" else { return nil }
        var price: Price?
        if let p = i.price, let final = p.final {
            let initial = max(p.initial ?? final, final)
            let pct = initial > 0 ? Int((Double(initial - final) / Double(initial) * 100).rounded()) : 0
            price = Price(currency: p.currency ?? "USD", finalCents: final, originalCents: initial, discountPercent: pct)
        }
        // A missing price is a free game, or one that isn't for sale yet.
        self.init(appID: i.id, name: i.name, capsuleURL: i.tiny_image.flatMap(URL.init(string:)), price: price, isFree: i.price == nil)
    }
}

// MARK: - GetItems wire format

/// Steam sends prices as strings ("2999") in this service, and ints elsewhere.
struct IntOrString: Decodable {
    let value: Int
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = i; return }
        if let s = try? c.decode(String.self), let i = Int(s) { value = i; return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an int")
    }
}

struct GetItemsResponse: Decodable {
    struct Item: Decodable {
        struct Assets: Decodable { let asset_url_format: String?; let small_capsule: String?; let header: String? }
        struct Discount: Decodable { let discount_end_date: Double?; let discount_description: String? }
        struct Offer: Decodable {
            let final_price_in_cents: IntOrString?
            let original_price_in_cents: IntOrString?
            let discount_pct: Int?
            let active_discounts: [Discount]?
        }
        struct Reviews: Decodable {
            struct Summary: Decodable { let review_count: Int?; let percent_positive: Int?; let review_score_label: String? }
            let summary_filtered: Summary?
        }
        struct PlatformInfo: Decodable { let windows: Bool?; let mac: Bool?; let linux: Bool?; let steam_deck_compat_category: Int? }
        struct Tag: Decodable { let tagid: Int; let weight: Int? }
        let id: Int
        let success: Int?
        let name: String?
        let is_free: Bool?
        let assets: Assets?
        let best_purchase_option: Offer?
        let reviews: Reviews?
        let platforms: PlatformInfo?
        let tags: [Tag]?
        let tagids: [Int]?
    }
    struct Resp: Decodable { let store_items: [Item]? }
    let response: Resp
}

extension StoreItem {
    init?(wire: GetItemsResponse.Item, currency: String = "USD") {
        guard wire.success == 1, let name = wire.name else { return nil }
        var capsule: URL?
        if let a = wire.assets, let fmt = a.asset_url_format, let file = a.small_capsule ?? a.header {
            capsule = URL(string: SteamClient.assetBase + fmt.replacingOccurrences(of: "${FILENAME}", with: file))
        }
        var price: Price?
        if let o = wire.best_purchase_option, let final = o.final_price_in_cents?.value {
            let original = o.original_price_in_cents?.value ?? final
            let ends = o.active_discounts?.compactMap(\.discount_end_date).max().map { Date(timeIntervalSince1970: $0) }
            price = Price(currency: currency, finalCents: final, originalCents: max(original, final),
                          discountPercent: o.discount_pct ?? 0, saleEnds: ends)
        }
        var reviews: ReviewSummary?
        if let s = wire.reviews?.summary_filtered, let pct = s.percent_positive, let count = s.review_count, count > 0 {
            reviews = ReviewSummary(percentPositive: pct, count: count, label: s.review_score_label ?? "")
        }
        let platforms = wire.platforms.map {
            Platforms(windows: $0.windows ?? true, mac: $0.mac ?? false, linux: $0.linux ?? false,
                      deck: Platforms.Deck(rawValue: $0.steam_deck_compat_category ?? 0) ?? .unknown)
        }
        let tagIDs = wire.tags.map { $0.sorted { ($0.weight ?? 0) > ($1.weight ?? 0) }.map(\.tagid) } ?? wire.tagids
        self.init(appID: wire.id, name: name, capsuleURL: capsule, price: price, isFree: wire.is_free ?? false,
                  reviews: reviews, platforms: platforms, tagIDs: tagIDs)
    }
}
