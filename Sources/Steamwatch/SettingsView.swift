import ServiceManagement
import SteamwatchCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var updater: Updater
    @AppStorage(SettingsKey.autoUpdateCheck) private var autoUpdate = true
    @AppStorage(SettingsKey.openInSteam) private var openInSteam = true

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
    @AppStorage(SettingsKey.ruleEnabled) private var ruleEnabled = false
    @AppStorage(SettingsKey.ruleMinDiscount) private var ruleMinDiscount = 75
    @AppStorage(SettingsKey.ruleMinRating) private var ruleMinRating = 85
    @AppStorage(SettingsKey.ruleMaxPrice) private var ruleMaxPrice = 0

    @State private var apiKey = Keychain.load(.apiKey) ?? ""
    @State private var profileStatus: String?
    @State private var resolving = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Steam account") {
                ForEach(store.localAccounts.filter { $0.steamID != steamID }) { account in
                    HStack {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        Text("Signed in to Steam on this Mac: **\(account.displayName)**")
                        Spacer()
                        Button("Use this account") {
                            store.useAccount(account)
                            profileStatus = "Connected to \(account.displayName)."
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
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
                Toggle("Open games in the Steam app", isOn: $openInSteam)
                    .disabled(!SteamLink.steamInstalled)
                    .help(SteamLink.steamInstalled ? "Otherwise store pages open in your browser." : "Steam isn't installed, so pages open in your browser.")
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

            Section("Deal rule") {
                Toggle("Tell me about any watched game that's a deal like this", isOn: $ruleEnabled)
                Group {
                    Picker("At least", selection: $ruleMinDiscount) {
                        ForEach([30, 40, 50, 60, 70, 75, 80, 90], id: \.self) { Text("\($0)% off").tag($0) }
                    }
                    Picker("Rated", selection: $ruleMinRating) {
                        Text("Any rating").tag(0)
                        ForEach([70, 80, 85, 90, 95], id: \.self) { Text("\($0)%+ positive").tag($0) }
                    }
                    Picker("Price", selection: $ruleMaxPrice) {
                        Text("Any price").tag(0)
                        ForEach([500, 1000, 1500, 2000, 3000], id: \.self) { Text("Under \(Format.price($0, currency: store.deals.first?.price.currency ?? "USD"))").tag($0) }
                    }
                }
                .disabled(!ruleEnabled)
                Text("Covers your whole wishlist and watched games without setting a limit on each. Matches show under the Picks chip and notify as new deals appear; games need 50+ reviews to count as rated.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Price limits") {
                if store.targets.cents.isEmpty {
                    Text("No targets yet. Right-click a deal in the popover and choose “Set Target…”.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.targets.byAppID.sorted { name($0.key) < name($1.key) }, id: \.key) { appID, cents in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name(appID)).lineLimit(1)
                                Text(currentPrice(appID)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Format.price(cents, currency: currency(appID))).monospacedDigit()
                            Button { store.setTarget(nil, for: appID) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).help("Remove target")
                        }
                    }
                }
            }

            Section("Watching (not on your wishlist)") {
                if store.watchlist.count == 0 {
                    Text("Press + in the popover to search the Steam store and watch any game, with an optional price limit.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.watchlist.appIDs.sorted { watchName($0) < watchName($1) }, id: \.self) { appID in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(watchName(appID)).lineLimit(1)
                                Text(currentPrice(appID) + (store.targets[appID].map { " · limit \(Format.price($0, currency: currency(appID)))" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Stop watching") { store.unwatch(appID) }.controlSize(.small)
                        }
                    }
                }
            }

            Section("Hidden games") {
                if store.hidden.count == 0 {
                    Text("Nothing hidden. Right-click a deal and choose “Hide (Bought It)” to keep it out of the list until it leaves your wishlist.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.hidden.appIDs.sorted { name($0) < name($1) }, id: \.self) { appID in
                        HStack {
                            Text(name(appID)).lineLimit(1)
                            Spacer()
                            Button("Show again") { store.unhide(appID) }.controlSize(.small)
                        }
                    }
                    Button("Show all \(store.hidden.count) again") { store.unhideAll() }.controlSize(.small)
                }
            }

            Section("About") {
                LabeledContent("Version", value: Updater.currentVersion)
                HStack {
                    Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let release = updater.availableRelease {
                        Button("Install \(release.version)") { Task { await updater.install(release) } }
                    } else {
                        Button("Check for Updates") { Task { await updater.check(userInitiated: true) } }
                            .disabled(updater.state == .checking)
                    }
                }
                Toggle("Check for updates automatically (daily)", isOn: $autoUpdate)
                HStack {
                    Link("Source on GitHub", destination: Links.repo)
                    Spacer()
                    Link(destination: Links.tip) { Label("Buy me a coffee", systemImage: "cup.and.saucer.fill") }
                }
                .font(.caption)
                Text("Steamwatch is free and open source, and not affiliated with Valve.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var updateStatus: String {
        switch updater.state {
        case .checking: return "Checking…"
        case .upToDate: return "Steamwatch is up to date."
        case .noReleases: return "No releases have been published yet."
        case .available(let r): return "Version \(r.version) is available."
        case .installing(let step): return step
        case .failed(let message): return message
        case .idle:
            return updater.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))." } ?? "Not checked yet."
        }
    }

    private func name(_ appID: AppID) -> String { store.items[appID]?.name ?? "App \(appID)" }
    private func watchName(_ appID: AppID) -> String { store.items[appID]?.name ?? store.watchlist.name(appID) ?? "App \(appID)" }
    private func currency(_ appID: AppID) -> String { store.items[appID]?.price?.currency ?? "USD" }
    private func currentPrice(_ appID: AppID) -> String {
        guard let p = store.items[appID]?.price else { return "Price unknown" }
        let s = "Now \(Format.price(p.finalCents, currency: p.currency))"
        return p.isOnSale ? s + " (−\(p.discountPercent)%)" : s
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
