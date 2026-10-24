import Foundation

/// What a user might paste to identify their account: a 17-digit SteamID64, a profile URL of either
/// kind, or a bare vanity name. Vanity names need an API key to resolve.
public enum SteamProfileRef: Equatable, Sendable {
    case id64(String)
    case vanity(String)

    public init?(parsing raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let range = s.range(of: "steamcommunity.com/", options: .caseInsensitive) {
            s = String(s[range.upperBound...])
            let parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { return nil }
            let value = parts[1].split(separator: "?").first.map(String.init) ?? parts[1]
            switch parts[0].lowercased() {
            case "profiles" where value.count == 17 && value.allSatisfy(\.isNumber): self = .id64(value)
            case "id" where !value.isEmpty: self = .vanity(value)
            default: return nil
            }
            return
        }
        if s.count == 17, s.allSatisfy(\.isNumber), s.hasPrefix("7656") {
            self = .id64(s)
        } else if s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            self = .vanity(s)
        } else {
            return nil
        }
    }

    public var profileURL: URL {
        switch self {
        case .id64(let v): return URL(string: "https://steamcommunity.com/profiles/\(v)/")!
        case .vanity(let v): return URL(string: "https://steamcommunity.com/id/\(v)/")!
        }
    }
}
