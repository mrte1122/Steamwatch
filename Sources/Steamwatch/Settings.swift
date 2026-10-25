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
    static let dealSort = "dealSort"                      // DealSort raw value
    static let autoUpdateCheck = "autoUpdateCheck"
    static let openInSteam = "openInSteam"              // store/community links open in the Steam app
    static let ruleEnabled = "ruleEnabled"                // the standing "any game at X% off" rule
    static let ruleMinDiscount = "ruleMinDiscount"        // percent
    static let ruleMinRating = "ruleMinRating"            // percent positive; 0 = any
    static let ruleMaxPrice = "ruleMaxPrice"              // cents; 0 = any
    static let mutedApps = "mutedApps"                    // [Int] app IDs that never notify
    static let quietEnabled = "quietEnabled"
    static let quietStart = "quietStart"                  // hour, 0...23
    static let quietEnd = "quietEnd"                      // hour, 0...23
    static let showSuggestions = "showSuggestions"
    static let suggestionsExpanded = "suggestionsExpanded" // popover disclosure state
    static let dismissedSuggestions = "dismissedSuggestions" // [Int] "Not interested"
    static let lastUpdateCheck = "lastUpdateCheck"        // Date
    static let notifiedUpdateVersion = "notifiedUpdateVersion"

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
            dealSort: "best",
            autoUpdateCheck: true,
            openInSteam: true,
            ruleEnabled: false,
            ruleMinDiscount: 75,
            ruleMinRating: 85,
            ruleMaxPrice: 0,
            mutedApps: [Int](),
            quietEnabled: false,
            quietStart: 22,
            quietEnd: 8,
            showSuggestions: true,
            suggestionsExpanded: true,
            dismissedSuggestions: [Int](),
        ])
    }
}

/// Opens Steam store and community pages in the Steam app when it's installed and the setting is
/// on (`steam://openurl/` takes any steampowered.com or steamcommunity.com address), else the browser.
@MainActor
enum SteamLink {
    static var steamInstalled: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "steam://openurl/https://store.steampowered.com/")!) != nil
    }

    static var opensInApp: Bool { UserDefaults.standard.bool(forKey: SettingsKey.openInSteam) && steamInstalled }

    static func open(_ url: URL) {
        let host = url.host ?? ""
        if opensInApp, host.hasSuffix("steampowered.com") || host.hasSuffix("steamcommunity.com"),
           let app = URL(string: "steam://openurl/" + url.absoluteString) {
            NSWorkspace.shared.open(app)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Links {
    static let repo = URL(string: "https://github.com/mrte1122/Steamwatch")!
    static let tip = URL(string: "https://ko-fi.com/mrte90")!
    static let apiKey = URL(string: "https://steamcommunity.com/dev/apikey")!
    static let privacy = URL(string: "https://steamcommunity.com/my/edit/settings")!
    static let wishlist = URL(string: "https://store.steampowered.com/wishlist/")!
}
