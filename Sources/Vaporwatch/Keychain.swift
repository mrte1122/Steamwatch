import Foundation
import Security

/// The Web API key lives in the login Keychain, never in UserDefaults or the cache files.
enum Keychain {
    enum Item: String {
        case apiKey = "steam-web-api-key"
    }

    private static let service = "Vaporwatch"
    /// The app was called Steamwatch before 0.6.0.
    private static let legacyService = "Steamwatch"

    /// Move a key saved under the old name to the new one, then remove the old entry. Safe to call
    /// every launch; returns what happened, for diagnostics.
    @discardableResult
    static func migrateLegacy() -> String {
        let doneKey = "keychainMigratedFromSteamwatch"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return "already migrated" }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        var notes: [String] = []
        for item in [Item.apiKey] {
            let legacy: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                         kSecAttrService as String: legacyService,
                                         kSecAttrAccount as String: item.rawValue]
            var read = legacy
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let found = SecItemCopyMatching(read as CFDictionary, &result)
            guard found == errSecSuccess, let data = result as? Data else { notes.append("\(item.rawValue): no legacy entry (\(found))"); continue }
            if load(item) == nil, !save(String(decoding: data, as: UTF8.self), item) {
                notes.append("\(item.rawValue): couldn't copy"); continue
            }
            // Only the app that created an item may delete it (errSecInvalidOwnerEdit otherwise), so
            // an entry from the old Steamwatch binary usually stays; it's the same key, and the
            // privacy policy says how to remove it in Keychain Access.
            let deleted = SecItemDelete(legacy as CFDictionary)
            notes.append("\(item.rawValue): copied" + (deleted == errSecSuccess ? ", old entry removed" : ", old entry left (\(deleted))"))
        }
        return notes.joined(separator: "; ")
    }

    private static func query(_ item: Item) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: item.rawValue]
    }

    static func load(_ item: Item) -> String? {
        var q = query(item)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        let s = String(decoding: data, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    @discardableResult
    static func save(_ value: String, _ item: Item) -> Bool {
        delete(item)
        guard !value.isEmpty else { return true }
        var q = query(item)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ item: Item) {
        SecItemDelete(query(item) as CFDictionary)
    }
}
