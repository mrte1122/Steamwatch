import AppKit
import Foundation

/// Theme for the popover and Settings window. The menu-bar item always follows the menu bar.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    static var current: ThemeChoice {
        ThemeChoice(rawValue: UserDefaults.standard.string(forKey: SettingsKey.theme) ?? "") ?? .system
    }
}

/// What the status item shows next to the glyph.
enum MenuBarMode: String, CaseIterable, Identifiable {
    case sales, playtime, both, glyph
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sales: return "Games on sale"
        case .playtime: return "Hours this week"
        case .both: return "Both"
        case .glyph: return "Icon only"
        }
    }
    static var current: MenuBarMode {
        MenuBarMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.menuBarMode) ?? "") ?? .sales
    }
}

/// `--demo`: sample data instead of your account. No network, no notifications.
enum Demo {
    static let isActive = CommandLine.arguments.contains("--demo")
}

enum SettingsKey {
    static let steamID = "steamID"                        // resolved SteamID64
    static let profileInput = "profileInput"              // what the user typed, for the Settings field
    static let countryCode = "countryCode"                // store region, e.g. "US"
    static let refreshInterval = "refreshInterval"        // seconds, 300...21600
    static let theme = "theme"
    static let menuBarMode = "menuBarMode"
    static let monochrome = "monochrome"
    static let showFriends = "showFriends"
    static let showPlaytime = "showPlaytime"
    static let notificationsEnabled = "notificationsEnabled"
    static let notifyTarget = "notifyTarget"
    static let notifyNewLow = "notifyNewLow"
    static let notifyFirstSale = "notifyFirstSale"
    static let notifyAnySale = "notifyAnySale"
    static let sentAlerts = "sentAlerts"                  // [String] DealAlert keys
    static let dealFilter = "dealFilter"                  // DealFilter raw value

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            steamID: "",
            profileInput: "",
            countryCode: Locale.current.region?.identifier ?? "US",
            refreshInterval: 1800.0,
            theme: ThemeChoice.system.rawValue,
            menuBarMode: MenuBarMode.sales.rawValue,
            monochrome: false,
            showFriends: true,
            showPlaytime: true,
            notificationsEnabled: true,
            notifyTarget: true,
            notifyNewLow: true,
            notifyFirstSale: true,
            notifyAnySale: false,
            dealFilter: "all",
        ])
    }
}

enum Links {
    static let repo = URL(string: "https://github.com/mrte1122/Steamwatch")!
    static let apiKey = URL(string: "https://steamcommunity.com/dev/apikey")!
    static let privacy = URL(string: "https://steamcommunity.com/my/edit/settings")!
    static let wishlist = URL(string: "https://store.steampowered.com/wishlist/")!
}
