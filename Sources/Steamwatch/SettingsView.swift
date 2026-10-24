import ServiceManagement
import SteamwatchCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: Store

    @AppStorage(SettingsKey.profileInput) private var profileInput = ""
    @AppStorage(SettingsKey.steamID) private var steamID = ""
    @AppStorage(SettingsKey.countryCode) private var country = "US"
    @AppStorage(SettingsKey.refreshInterval) private var refreshInterval = 1800.0
    @AppStorage(SettingsKey.theme) private var theme = ThemeChoice.system.rawValue
    @AppStorage(SettingsKey.menuBarMode) private var menuBarMode = MenuBarMode.sales.rawValue
    @AppStorage(SettingsKey.monochrome) private var monochrome = false
    @AppStorage(SettingsKey.showPlaytime) private var showPlaytime = true
    @AppStorage(SettingsKey.showFriends) private var showFriends = true
    @AppStorage(SettingsKey.notificationsEnabled) private var notificationsEnabled = true
    @AppStorage(SettingsKey.notifyTarget) private var notifyTarget = true
    @AppStorage(SettingsKey.notifyNewLow) private var notifyNewLow = true
    @AppStorage(SettingsKey.notifyFirstSale) private var notifyFirstSale = true
    @AppStorage(SettingsKey.notifyAnySale) private var notifyAnySale = false

    @State private var apiKey = Keychain.load(.apiKey) ?? ""
    @State private var profileStatus: String?
    @State private var resolving = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Steam account") {
                HStack {
                    TextField("Profile URL or SteamID64", text: $profileInput, prompt: Text("https://steamcommunity.com/id/yourname"))
                        .onSubmit { Task { await connect() } }
                    Button(resolving ? "Checking…" : "Connect") { Task { await connect() } }.disabled(resolving || profileInput.isEmpty)
                }
                if let s = profileStatus {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                } else if !steamID.isEmpty {
                    Text("Connected: \(steamID)" + (store.me.map { " (\($0.name))" } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
                Text("The wishlist and prices need no sign-in, but your profile's Game details must be public.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Steam privacy settings", destination: Links.privacy).font(.caption)
            }

            Section("Web API key (optional)") {
                SecureField("API key", text: $apiKey, prompt: Text("Paste your key"))
                    .onSubmit { saveKey() }
                HStack {
                    Button("Save key") { saveKey() }.disabled(apiKey == (Keychain.load(.apiKey) ?? ""))
                    if !apiKey.isEmpty { Button("Remove") { apiKey = ""; saveKey() } }
                }
                Text("Unlocks playtime and friends online. Free from Steam for accounts that have made a purchase; stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Get a key at steamcommunity.com/dev/apikey", destination: Links.apiKey).font(.caption)
            }

            Section("Store") {
                TextField("Country code", text: $country, prompt: Text("US"))
                    .onChange(of: country) { _, new in
                        let c = String(new.uppercased().prefix(2))
                        if c != new { country = c }
                    }
                Picker("Check every", selection: $refreshInterval) {
                    Text("15 minutes").tag(900.0)
                    Text("30 minutes").tag(1800.0)
                    Text("1 hour").tag(3600.0)
                    Text("3 hours").tag(10_800.0)
                }
            }

            Section("Menu bar") {
                Picker("Show", selection: $menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Monochrome icon", isOn: $monochrome)
                Picker("Appearance", selection: $theme) {
                    ForEach(ThemeChoice.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Playtime section", isOn: $showPlaytime)
                Toggle("Friends online", isOn: $showFriends)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }

            Section("Notifications") {
                Toggle("Notify me", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, on in if on { store.notifier.requestAuthorization() } }
                Group {
                    Toggle("A game drops to my target price", isOn: $notifyTarget)
                    Toggle("A game hits a new low (since I started watching)", isOn: $notifyNewLow)
                    Toggle("A game goes on sale for the first time", isOn: $notifyFirstSale)
                    Toggle("Any wishlist game goes on sale", isOn: $notifyAnySale)
                }
                .disabled(!notificationsEnabled)
                Text("Right-click a game in the popover to set its target price.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Steamwatch \(SteamClient.version)").foregroundStyle(.secondary)
                    Spacer()
                    Link("Source", destination: Links.repo)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func saveKey() {
        Keychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), .apiKey)
        apiKey = Keychain.load(.apiKey) ?? ""
        Task { await store.refresh(force: true) }
    }

    private func connect() async {
        guard let ref = SteamProfileRef(parsing: profileInput) else {
            profileStatus = "That doesn't look like a Steam profile URL, SteamID64 or custom URL name."
            return
        }
        resolving = true
        defer { resolving = false }
        do {
            let id: String
            switch ref {
            case .id64(let v): id = v
            case .vanity(let name):
                guard store.hasAPIKey else {
                    profileStatus = "Custom URL names need an API key to look up. Paste the steamcommunity.com/profiles/… link instead (Steam → your profile → copy the URL after switching off the custom URL), or add a key below."
                    return
                }
                id = try await store.client().resolveVanity(name)
            }
            let wishlist = try await store.client().wishlist(steamID: id)
            let changed = id != steamID
            steamID = id
            profileStatus = wishlist.isEmpty ? "Connected, but the wishlist came back empty: it's either empty or private." : "Connected: \(wishlist.count) games on the wishlist."
            if changed { store.resetForNewProfile() } else { await store.refresh(force: true) }
        } catch {
            profileStatus = error.localizedDescription
        }
    }
}
