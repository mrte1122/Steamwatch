import ServiceManagement
import SteamwatchCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var updater: Updater
    /// Which tab opens first; screenshots set it.
    var initialTab = "general"
    @State private var tab = "general"
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
    @AppStorage(SettingsKey.quietEnabled) private var quietEnabled = false
    @AppStorage(SettingsKey.quietStart) private var quietStart = 22
    @AppStorage(SettingsKey.quietEnd) private var quietEnd = 8
    @AppStorage(SettingsKey.showSuggestions) private var showSuggestions = true

    @State private var apiKey = Keychain.load(.apiKey) ?? ""
    @State private var profileStatus: String?
    @State private var resolving = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            notifications.tabItem { Label("Notifications", systemImage: "bell") }.tag("notifications")
            games.tabItem { Label("Games", systemImage: "gamecontroller") }.tag("games")
            about.tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .padding(16)
        .frame(width: 500, height: 520)
        .onAppear { tab = initialTab }
    }

    private var general: some View {
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
                    TextField("Profile URL or SteamID64", text: Demo.isActive ? .constant(DemoData.me.profileURL.absoluteString) : $profileInput, prompt: Text("https://steamcommunity.com/id/yourname"))
                        .onSubmit { Task { await connect() } }
                    Button(resolving ? "Checking…" : "Connect") { Task { await connect() } }.disabled(resolving || profileInput.isEmpty)
                }
                if let s = profileStatus {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                } else if Demo.isActive {
                    Text("Connected: \(DemoData.me.steamID) (\(DemoData.me.name))").font(.caption).foregroundStyle(.secondary)
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
                    .help(store.friendsPrivate ? "Your friends list is private on Steam, so nobody can be shown." : "Needs a Web API key and a public friends list.")
                if store.friendsPrivate, showFriends {
                    Text("Your Steam friends list is private, so friends online stays empty. Steam → Edit Profile → Privacy → Friends List: Public to change that.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("“You might like” suggestions", isOn: $showSuggestions)
                    .onChange(of: showSuggestions) { _, on in if on { Task { await store.refreshSuggestions(force: true) } } }
                    .help("Discounted, well-reviewed games that share tags with your wishlist. Checked twice a day.")
                Toggle("Open games in the Steam app", isOn: $openInSteam)
                    .disabled(!SteamLink.steamInstalled)
                    .help(SteamLink.steamInstalled ? "Otherwise store pages open in your browser." : "Steam isn't installed, so pages open in your browser.")
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
        .formStyle(.grouped)
    }

    private var notifications: some View {
        Form {
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

            Section("Quiet hours") {
                Toggle("Hold notifications overnight", isOn: $quietEnabled)
                HStack {
                    Picker("From", selection: $quietStart) { ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) } }
                    Picker("Until", selection: $quietEnd) { ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) } }
                }
                .disabled(!quietEnabled)
                Text("Deals found in this window are delivered together on the first check after it ends, as one digest if there are several.")
                    .font(.caption).foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
    }

    private var games: some View {
        Form {
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

            Section("Muted") {
                if store.muted.isEmpty {
                    Text("Muted games stay in the list but never notify. Right-click a deal, or use Mute on a notification.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.muted.sorted { name($0) < name($1) }, id: \.self) { appID in
                        HStack {
                            Text(name(appID)).lineLimit(1)
                            Spacer()
                            Button("Unmute") { store.toggleMute(appID) }.controlSize(.small)
                        }
                    }
                }
            }

            Section("Suggestions") {
                HStack {
                    Text(store.dismissed.isEmpty ? "Suggestions you mark “Not interested” are never shown again."
                         : "\(store.dismissed.count) suggestion\(store.dismissed.count == 1 ? "" : "s") marked “Not interested”.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !store.dismissed.isEmpty { Button("Reset") { store.resetDismissedSuggestions() }.controlSize(.small) }
                    Button(store.isSuggesting ? "Finding…" : "Refresh Now") { Task { await store.refreshSuggestions(force: true) } }
                        .controlSize(.small).disabled(store.isSuggesting)
                }
                if !store.hasAPIKey {
                    Text("With a Web API key, games you already own are left out too.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Marked as owned") {
                if store.ownedManual.isEmpty {
                    Text("Games you mark “I already own this” in For You are listed here and never suggested.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.ownedManual.sorted(), id: \.self) { appID in
                        HStack {
                            Text(ownedName(appID)).lineLimit(1)
                            Spacer()
                            Button("Remove") { store.markOwned(appID, false) }.controlSize(.small)
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
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        Form {
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

    private func hourLabel(_ h: Int) -> String {
        var c = DateComponents(); c.hour = h
        return Calendar.current.date(from: c).map { $0.formatted(date: .omitted, time: .shortened) } ?? "\(h):00"
    }

    private func name(_ appID: AppID) -> String { store.items[appID]?.name ?? "App \(appID)" }
    private func ownedName(_ appID: AppID) -> String {
        store.items[appID]?.name ?? store.suggestions?.suggestions.first { $0.id == appID }?.item.name ?? "App \(appID)"
    }
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
