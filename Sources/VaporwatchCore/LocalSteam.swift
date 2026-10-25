import Foundation

/// An account the Steam client on this computer has signed in with, from its `loginusers.vdf`.
/// Read locally so first-run setup can offer "Use this account" instead of asking for a profile URL.
public struct LocalSteamAccount: Equatable, Sendable, Identifiable {
    public let steamID: String
    public let accountName: String
    public let personaName: String
    /// The account the client last signed in with.
    public let mostRecent: Bool
    public let lastLogin: Date?

    public var id: String { steamID }
    public var displayName: String { personaName.isEmpty ? accountName : personaName }
}

public enum LocalSteam {
    /// Where the Steam client keeps `loginusers.vdf` on each platform, most likely first.
    public static func loginUsersPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                       environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        #if os(macOS)
        return [home.appendingPathComponent("Library/Application Support/Steam/config/loginusers.vdf")]
        #elseif os(Windows)
        let roots = [environment["ProgramFiles(x86)"], environment["ProgramFiles"]].compactMap { $0 }
        return roots.map { URL(fileURLWithPath: $0).appendingPathComponent("Steam/config/loginusers.vdf") }
        #else
        return [".steam/steam/config/loginusers.vdf", ".local/share/Steam/config/loginusers.vdf",
                ".var/app/com.valvesoftware.Steam/.local/share/Steam/config/loginusers.vdf"]
            .map { home.appendingPathComponent($0) }
        #endif
    }

    /// Accounts found on this computer, most recent first; empty if Steam isn't installed.
    public static func accounts(paths: [URL] = loginUsersPaths()) -> [LocalSteamAccount] {
        for url in paths {
            if let data = FileManager.default.contents(atPath: url.path) {
                let found = parseLoginUsers(String(decoding: data, as: UTF8.self))
                if !found.isEmpty { return found }
            }
        }
        return []
    }

    public static func parseLoginUsers(_ text: String) -> [LocalSteamAccount] {
        guard case .object(let root)? = VDF.parse(text), case .object(let users)? = root["users"] else { return [] }
        return users.compactMap { id, value -> LocalSteamAccount? in
            guard id.count == 17, id.allSatisfy(\.isNumber), case .object(let u) = value else { return nil }
            // Key case varies between Steam versions ("Timestamp" vs "timestamp"), so match loosely.
            let fields = Dictionary(u.compactMap { k, v -> (String, String)? in
                if case .string(let s) = v { return (k.lowercased(), s) }; return nil
            }, uniquingKeysWith: { a, _ in a })
            func str(_ k: String) -> String { fields[k.lowercased()] ?? "" }
            return LocalSteamAccount(steamID: id, accountName: str("AccountName"), personaName: str("PersonaName"),
                                     mostRecent: str("MostRecent") == "1",
                                     lastLogin: Double(str("Timestamp")).map { Date(timeIntervalSince1970: $0) })
        }
        .sorted { a, b in
            a.mostRecent != b.mostRecent ? a.mostRecent : (a.lastLogin ?? .distantPast) > (b.lastLogin ?? .distantPast)
        }
    }
}

/// Valve's KeyValues text format: quoted keys followed by a quoted value or a braced block.
enum VDF: Equatable {
    case string(String)
    case object([String: VDF])

    static func parse(_ text: String) -> VDF? {
        var tokens = tokenize(text)[...]
        var root: [String: VDF] = [:]
        while let key = tokens.popFirst() {
            guard case .quoted(let k) = key, let v = value(&tokens) else { return root.isEmpty ? nil : .object(root) }
            root[k] = v
        }
        return .object(root)
    }

    private enum Token: Equatable { case quoted(String), open, close }

    private static func value(_ tokens: inout ArraySlice<Token>) -> VDF? {
        switch tokens.popFirst() {
        case .quoted(let s)?: return .string(s)
        case .open?:
            var obj: [String: VDF] = [:]
            while let t = tokens.first {
                if t == .close { tokens.removeFirst(); return .object(obj) }
                guard case .quoted(let k)? = tokens.popFirst(), let v = value(&tokens) else { return nil }
                obj[k] = v
            }
            return .object(obj)   // unterminated block: keep what was read
        default: return nil
        }
    }

    private static func tokenize(_ text: String) -> [Token] {
        var out: [Token] = []
        var it = text.makeIterator()
        while let c = it.next() {
            switch c {
            case "{": out.append(.open)
            case "}": out.append(.close)
            case "\"":
                var s = ""
                while let d = it.next(), d != "\"" {
                    if d == "\\", let e = it.next() { s.append(e == "n" ? "\n" : e == "t" ? "\t" : e) } else { s.append(d) }
                }
                out.append(.quoted(s))
            case "/":
                // `// comment` to end of line
                while let d = it.next(), d != "\n" {}
            default: continue
            }
        }
        return out
    }
}
