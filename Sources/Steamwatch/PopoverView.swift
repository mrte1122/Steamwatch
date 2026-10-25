import Charts
import SteamwatchCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: Store
    @ObservedObject var updater: Updater
    var openSettings: () -> Void
    /// Screenshots only: open with the store-search panel showing this query.
    var previewSearch: String?

    @AppStorage(SettingsKey.dealFilter) private var filterRaw = DealFilter.all.rawValue
    @AppStorage(SettingsKey.dealSort) private var sortRaw = DealSort.best.rawValue
    @AppStorage(SettingsKey.showPlaytime) private var showPlaytime = true
    @AppStorage(SettingsKey.showFriends) private var showFriends = true
    @AppStorage(SettingsKey.showSuggestions) private var showSuggestions = true
    @AppStorage(SettingsKey.popoverTab) private var tabRaw = "deals"
    @State private var query = ""
    @State private var editingTarget: AppID?
    /// The store-search panel replaces the deal list while open.
    @State private var adding = false
    /// Keyboard: the deal ↑/↓ moves to and Return opens, and the search field ⌘F jumps to.
    @State private var selection: AppID?
    @State private var searchShown = false
    @FocusState private var searchFocused: Bool

    /// Rows visible before the list scrolls.
    private let visibleRows = 6

    private var filter: DealFilter { DealFilter(rawValue: filterRaw) ?? .all }
    private var sort: DealSort { DealSort(rawValue: sortRaw) ?? .best }
    private var shown: [Deal] { sort.sorted(DealEngine.filter(store.deals, filter, query: query, rule: store.rule)) }
    /// Chips with nothing in them are left out (All and the selected one always stay); Picks needs a rule.
    private var chips: [DealFilter] {
        DealFilter.allCases.filter { f in
            if f == .all || f == filter { return true }
            if f == .picks, store.rule == nil { return false }
            return !DealEngine.filter(store.deals, f, rule: store.rule).isEmpty
        }
    }

    /// Fixed so the popover never resizes (and macOS never slides it sideways) when content changes.
    static let height: CGFloat = 640

    private var onForYou: Bool { showSuggestions && tabRaw == "forYou" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            locationBanner
            updateBanner
            if store.needsSetup {
                SetupCard(store: store, openSettings: openSettings)
                Spacer(minLength: 0)
            } else if adding {
                AddGamePanel(store: store, initialQuery: previewSearch ?? "") { adding = false }
                Spacer(minLength: 0)
            } else {
                if showSuggestions { tabPicker }
                if onForYou {
                    ForYouTab(store: store)
                } else {
                    errorBanner
                    saleBanner
                    if searchShown || store.deals.count > visibleRows || !query.isEmpty || filter != .all || sort != .best { filterBar }
                    dealsSection.frame(maxHeight: .infinity, alignment: .top)
                    if showPlaytime { playtimeSection }
                }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340, height: Self.height)
        .onAppear { if previewSearch != nil { adding = true } }
        .background(shortcuts)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.return) { openSelection() }
        .onKeyPress(.escape) { backOut() }
    }

    private var tabPicker: some View {
        Picker("View", selection: $tabRaw) {
            Text("Deals \(store.deals.count)").tag("deals")
            Text("For You \(store.visibleSuggestions.count)").tag("forYou")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: Keyboard

    /// Invisible buttons that carry the ⌘ shortcuts.
    private var shortcuts: some View {
        VStack {
            Button("Search") {
                adding = false
                searchShown = true
                DispatchQueue.main.async { searchFocused = true }
            }
            .keyboardShortcut("f", modifiers: .command)
            Button("Watch a game") { adding = true }.keyboardShortcut("n", modifiers: .command)
            Button("Refresh") { Task { await store.refresh(force: true) } }.keyboardShortcut("r", modifiers: .command)
            Button("Settings") { openSettings() }.keyboardShortcut(",", modifiers: .command)
            Button("Deals") { adding = false; tabRaw = "deals" }.keyboardShortcut("1", modifiers: .command)
            Button("For You") { adding = false; tabRaw = "forYou" }.keyboardShortcut("2", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !adding, !onForYou, !shown.isEmpty else { return .ignored }
        let ids = shown.map(\.id)
        let i = selection.flatMap { ids.firstIndex(of: $0) }
        let next = i.map { min(max($0 + step, 0), ids.count - 1) } ?? (step > 0 ? 0 : ids.count - 1)
        selection = ids[next]
        return .handled
    }

    private func openSelection() -> KeyPress.Result {
        guard !adding, !onForYou, let id = selection, let deal = shown.first(where: { $0.id == id }) else { return .ignored }
        SteamLink.open(deal.item.storeURL)
        return .handled
    }

    /// Esc backs out one level (search panel, query, filter, selection); with nothing to undo it's
    /// left to the popover, which closes.
    private func backOut() -> KeyPress.Result {
        if adding { adding = false; return .handled }
        if !query.isEmpty { query = ""; return .handled }
        if searchShown { searchShown = false; searchFocused = false; return .handled }
        if filter != .all { filterRaw = DealFilter.all.rawValue; return .handled }
        if selection != nil { selection = nil; return .handled }
        return .ignored
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { adding.toggle() } label: { Image(systemName: adding ? "xmark" : "plus") }
                .buttonStyle(.borderless)
                .help(adding ? "Back to deals" : "Watch any game on the Steam store")
                .disabled(store.needsSetup)
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                if store.isRefreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .disabled(store.isRefreshing || store.needsSetup)
        }
    }

    private var title: String {
        if store.needsSetup || !store.hasData { return "Steamwatch" }
        switch store.deals.count {
        case 0: return "Nothing on sale"
        case 1: return store.watchlist.count > 0 ? "1 game on sale" : "1 wishlist game on sale"
        default: return "\(store.deals.count) \(store.watchlist.count > 0 ? "" : "wishlist ")games on sale"
        }
    }

    private var subtitle: String {
        if store.needsSetup { return "Wishlist sale watcher" }
        var parts: [String] = []
        if let u = store.lastUpdated { parts.append("updated \(Format.relative(u, now: store.now))") }
        if store.wishlistCount > 0 { parts.append("\(store.wishlistCount) on wishlist") }
        if store.watchlist.count > 0 { parts.append("\(store.watchlist.count) watched") }
        if store.hidden.count > 0 { parts.append("\(store.hidden.count) hidden") }
        if store.staleCount > 0 { parts.append("\(store.staleCount) stale") }
        return parts.isEmpty ? (store.isRefreshing ? "Checking the store…" : "Wishlist sale watcher") : parts.joined(separator: " · ")
    }

    /// Updates can't install from a translocated copy (opened straight from Downloads), so say how
    /// to fix it up front. Other "can't update here" cases don't need a banner: the update banner
    /// offers a download instead.
    @ViewBuilder private var locationBanner: some View {
        if Updater.isTranslocated {
            VStack(alignment: .leading, spacing: 6) {
                if Updater.movedCopyURL != nil {
                    Label("Steamwatch is in Applications now", systemImage: "checkmark.circle").font(.callout.weight(.medium))
                    Text("This window is still the temporary copy that was opened from Downloads. Relaunch to switch to the one in Applications.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("Relaunch from Applications") { Updater.relaunchFromMovedCopy() }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                } else {
                    Label("Move Steamwatch to Applications", systemImage: "folder.badge.plus").font(.callout.weight(.medium))
                    Text("It's running from a temporary copy, so updates can't install. Drag Steamwatch from Downloads into Applications; this banner will then offer to relaunch it from there.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Applications Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }
                        Button("Quit Steamwatch") { NSApp.terminate(nil) }
                    }
                    .controlSize(.small)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private var updateBanner: some View {
        switch updater.state {
        case .available(let release):
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Steamwatch \(release.version) is available").font(.callout.weight(.medium))
                    Link("What's new", destination: release.pageURL).font(.caption)
                }
                Spacer()
                if Updater.installLocationProblem == nil {
                    Button("Update") { Task { await updater.install(release) } }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                } else {
                    Link("Download", destination: release.pageURL).controlSize(.small)
                }
            }
            .padding(8)
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .installing(let step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step).font(.callout)
                Spacer()
            }
            .padding(8)
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("Update failed").font(.caption.bold())
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                Link("Open the releases page", destination: Updater.releasesPage).font(.caption)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var saleBanner: some View {
        if let event = store.saleEvent {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color(ns: Theme.readable(Theme.highlight)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Big Steam sale").font(.callout.weight(.semibold))
                    Text("+\(event.extra(store.deals)) games discounted since it began")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let ends = event.ends {
                    Text("ends \(Format.saleEnds(ends, now: store.now))").font(.caption.weight(.medium)).monospacedDigit()
                }
            }
            .padding(8)
            .card(tint: Color(ns: Theme.highlight))
        }
    }

    @ViewBuilder private var errorBanner: some View {
        if let e = store.lastError {
            Label(e, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Filter bar

    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Search deals", text: $query).textFieldStyle(.plain).font(.callout)
                        .focused($searchFocused)
                        .onKeyPress(.downArrow) { move(1) }
                        .onKeyPress(.upArrow) { move(-1) }
                        .onKeyPress(.return) { openSelection() }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .card()
                Menu {
                    Picker("Sort", selection: $sortRaw) {
                        ForEach(DealSort.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label(sort == .best ? "Sort" : sort.title, systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                        .foregroundStyle(sort == .best ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color(ns: Theme.readable(Theme.accent))))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Order the list")
            }
            FlowLayout(spacing: 4) {
                ForEach(chips) { f in
                    let count = DealEngine.filter(store.deals, f, rule: store.rule).count
                    Button {
                        filterRaw = f.rawValue
                    } label: {
                        Text(f == .all ? f.title : "\(f.title) \(count)")
                            .font(.caption.weight(filter == f ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(filter == f ? Color(ns: Theme.accent).opacity(0.2) : Color.secondary.opacity(0.08),
                                        in: Capsule())
                            .foregroundStyle(filter == f ? Color(ns: Theme.readable(Theme.accent)) : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0 && f != .all)
                }
            }
        }
    }

    // MARK: Deals

    @ViewBuilder private var dealsSection: some View {
        if !store.hasData, store.lastError == nil {
            HStack { ProgressView().controlSize(.small); Text("Checking your wishlist…").font(.callout).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity).padding(14).card()
        } else if store.deals.isEmpty, store.hasData {
            VStack(spacing: 4) {
                Image(systemName: "tag.slash").font(.title2).foregroundStyle(.secondary)
                Text("None of your wishlist is discounted right now.").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(14).card()
        } else if shown.isEmpty {
            Text("No deals match.").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(14).card()
        } else {
            ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { deal in
                        DealRow(deal: deal, now: store.now, sort: sort, selected: selection == deal.id, watched: store.watchlist.contains(deal.id), picked: store.rule?.matches(deal) ?? false, editing: editingTarget == deal.id,
                                beginEdit: { editingTarget = deal.id },
                                commit: { cents in store.setTarget(cents, for: deal.id); editingTarget = nil },
                                hide: { store.hide(deal.id) },
                                muted: store.muted.contains(deal.id), toggleMute: { store.toggleMute(deal.id) })
                        .id(deal.id)
                    }
                }
            }
            .onChange(of: selection) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
            }
        }
    }

    // MARK: Playtime

    @ViewBuilder private var playtimeSection: some View {
        if store.hasAPIKey, store.hasData || Demo.isActive {
            PlaytimeCard(store: store)
        } else if store.hasData {
            HStack(spacing: 6) {
                Image(systemName: "gamecontroller").foregroundStyle(.secondary)
                Text("Add a Steam Web API key in Settings for playtime and friends.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10).card()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if showFriends, store.hasAPIKey, !store.friendsOnline.isEmpty {
                FriendsMenu(friends: store.friendsOnline)
            } else if let e = store.playerError {
                Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(e)
            } else if let me = store.me, let game = me.currentGame {
                Label("Playing \(game)", systemImage: "play.fill").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { SteamLink.open(Links.wishlist) } label: { Image(systemName: "list.star") }.help("Open your Steam wishlist")
            Link(destination: Links.tip) { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                .help("Enjoying Steamwatch? Buy me a coffee on Ko-fi")
            Button { openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Steamwatch")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Rows and cards

struct DealRow: View {
    static let height: CGFloat = 50

    let deal: Deal
    let now: Date
    var sort: DealSort = .best
    /// Highlighted by the keyboard.
    var selected = false
    /// Added through store search rather than the Steam wishlist.
    var watched = false
    /// Matches the user's standing deal rule.
    var picked = false
    let editing: Bool
    let beginEdit: () -> Void
    let commit: (Int?) -> Void
    let hide: () -> Void
    var muted = false
    var toggleMute: () -> Void = {}
    @State private var text = ""
    @Environment(\.openURL) private var openURL

    private var accent: Color { Color(ns: Theme.readable(Theme.highlight)) }

    var body: some View {
        HStack(spacing: 10) {
            CapsuleArt(url: deal.item.capsuleURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(deal.item.name).font(.callout.weight(.medium)).lineLimit(1).minimumScaleFactor(0.85)
                    .foregroundStyle(deal.meetsTarget ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
                if editing {
                    HStack(spacing: 4) {
                        TextField("Target", text: $text, prompt: Text("14.99"))
                            .textFieldStyle(.roundedBorder).controlSize(.mini).frame(width: 64)
                            .onSubmit { commit(Format.cents(parsing: text)) }
                        Button("Set") { commit(Format.cents(parsing: text)) }.controlSize(.mini)
                        if deal.targetCents != nil { Button("Clear") { commit(nil) }.controlSize(.mini) }
                    }
                } else {
                    Text(detail).font(.caption).lineLimit(1)
                        .foregroundStyle(deal.meetsTarget ? AnyShapeStyle(accent)
                                         : deal.endsSoon(now: now) ? AnyShapeStyle(Color(ns: Theme.readable(.systemOrange))) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 4)
            // Badge and final price side by side, original price beneath: keeps the column narrow
            // so long names get the room.
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 5) {
                    Text(deal.price.discountPercent > 0 ? "−\(deal.price.discountPercent)%" : "limit")
                        .font(.caption2.weight(.semibold)).lineLimit(1).fixedSize()
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(deal.meetsTarget ? Color(ns: Theme.highlight) : Color(ns: Theme.highlight).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(deal.meetsTarget ? .white : accent)
                    Text(Format.price(deal.price.finalCents, currency: deal.price.currency)).font(.callout.weight(.medium)).monospacedDigit()
                }
                if deal.price.originalCents > deal.price.finalCents {
                    Text(Format.price(deal.price.originalCents, currency: deal.price.currency))
                        .font(.caption2).strikethrough().foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .card(tint: deal.meetsTarget ? Color(ns: Theme.highlight) : nil)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
        .contentShape(Rectangle())
        .onTapGesture { if !editing { SteamLink.open(deal.item.storeURL) } }
        .contextMenu {
            Button(SteamLink.opensInApp ? "Open in Steam" : "Open Store Page") { SteamLink.open(deal.item.storeURL) }
            if SteamLink.opensInApp { Button("Open in Browser") { openURL(deal.item.storeURL) } }
            Divider()
            Button("Set Target to \(Format.price(deal.price.finalCents, currency: deal.price.currency))") { commit(deal.price.finalCents) }
            let quick = QuickLimit.options(for: deal)
            if !quick.isEmpty {
                Menu("Notify Me At") {
                    ForEach(quick, id: \.cents) { q in
                        Button("\(Format.price(q.cents, currency: deal.price.currency)) (\(q.label))") { commit(q.cents) }
                    }
                }
            }
            Button(deal.targetCents == nil ? "Set Target Price…" : "Change Target Price…") {
                text = deal.targetCents.map { String(format: "%.2f", Double($0) / 100) } ?? ""
                beginEdit()
            }
            if deal.targetCents != nil { Button("Clear Target") { commit(nil) } }
            Divider()
            Button(muted ? "Unmute Notifications" : "Mute Notifications") { toggleMute() }
            Button("Hide (Bought It)") { hide() }
        }
        .help("Click to open in the Steam store. Right-click for targets or to hide.")
    }

    private var detail: String {
        var parts: [String] = []
        let cur = deal.price.currency
        if deal.meetsTarget, let t = deal.targetCents { parts.append("Under \(Format.price(t, currency: cur)) target") }
        else if let t = deal.targetCents { parts.append("target \(Format.price(t, currency: cur))") }
        if deal.isFirstSale { parts.append("first sale ever") }
        else if deal.isNewLow { parts.append("new low") }
        else if !deal.meetsTarget, let low = deal.lowestSeenCents, low < deal.price.finalCents { parts.append("low seen \(Format.price(low, currency: cur))") }
        if picked, !deal.meetsTarget { parts.insert("your rule", at: 0) }
        if watched { parts.append("watching") }
        else if deal.priority > 0, deal.priority <= 30 { parts.append("#\(deal.priority) on wishlist") }
        if let ends = deal.price.saleEnds {
            if deal.endsSoon(now: now) { parts.insert("ends \(Format.saleEnds(ends, now: now))", at: 0) }
            else { parts.append("ends \(Format.saleEnds(ends, now: now))") }
        }
        // The review score leads when the list is sorted by it, so the order is legible; otherwise
        // it trails, where the row can afford to truncate it.
        if let r = deal.item.reviews {
            if sort == .rating { parts.insert(r.short, at: 0) } else { parts.append("\(r.percentPositive)% positive") }
        }
        return parts.joined(separator: " · ")
    }
}

/// 56×26 game art, loaded only when the row is on screen (LazyVStack), with a placeholder while it
/// loads (or in demo mode without network).
struct CapsuleArt: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: Demo.hidesArt ? nil : url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                .overlay(Image(systemName: "gamecontroller").font(.caption).foregroundStyle(.tertiary))
        }
        .frame(width: 56, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct PlaytimeCard: View {
    @ObservedObject var store: Store

    var body: some View {
        let days = store.playtime.daily(days: 7, now: store.now)
        let week = days.reduce(0) { $0 + $1.minutes }
        // Daily bars need a day of samples; until then the honest number is Steam's two-week total.
        let tracking = week > 0 || store.playtime.samples.count > 1 && (store.playtime.samples.first.map { store.now.timeIntervalSince($0.date) > 86_400 } ?? false)
        let peak = max(60, days.map(\.minutes).max() ?? 0)
        let recent = store.recentGames.sorted { $0.minutesTwoWeeks > $1.minutesTwoWeeks }.prefix(3)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(tracking ? "Played this week" : "Played in the last 2 weeks", systemImage: "gamecontroller")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Format.hours(tracking ? week : store.twoWeekMinutes)).font(.callout.weight(.medium)).monospacedDigit()
                if tracking, let avg = store.playtime.weeklyAverageMinutes(now: store.now) {
                    Text("avg \(Format.hours(avg))").font(.caption2).foregroundStyle(.secondary)
                } else if tracking, store.twoWeekMinutes > 0 {
                    Text("\(Format.hours(store.twoWeekMinutes)) / 2 wk").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !recent.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(recent)) { g in
                        VStack(alignment: .leading, spacing: 2) {
                            GameArt(appID: g.appID)
                            Text(g.name).font(.caption2).lineLimit(1)
                            Text(Format.hours(g.minutesTwoWeeks)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { SteamLink.open(URL(string: "https://store.steampowered.com/app/\(g.appID)/")!) }
                        .help("\(g.name): \(Format.hours(g.minutesTwoWeeks)) in the last two weeks, \(Format.hours(g.minutesForever)) in total")
                    }
                    ForEach(0..<(3 - recent.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            }
            if tracking {
                Chart(days) { day in
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Minutes", day.minutes))
                        .foregroundStyle(Calendar.current.isDateInToday(day.day) ? Color(ns: Theme.accent) : Color.secondary.opacity(0.35))
                        .cornerRadius(2)
                }
                // A fixed floor keeps quiet days looking quiet instead of stretching to fill.
                .chartYScale(domain: 0...peak)
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 28)
            } else if store.recentGames.isEmpty {
                Text("Nothing played in the last two weeks.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Daily bars fill in from today as Steamwatch keeps watching.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .card()
    }
}

/// Steam's capsule art for any app, straight from its CDN by ID (recently played games don't come
/// with store data). Placeholder while loading, or in demo mode.
struct GameArt: View {
    let appID: AppID
    var body: some View {
        AsyncImage(url: Demo.hidesArt ? nil : URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/capsule_231x87.jpg")) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                .overlay(Image(systemName: "gamecontroller").font(.caption2).foregroundStyle(.tertiary))
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct FriendsMenu: View {
    let friends: [PlayerSummary]
    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu {
            ForEach(friends) { f in
                Button { SteamLink.open(f.profileURL) } label: {
                    Text(f.currentGame.map { "\(f.name) · \($0)" } ?? f.name)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(Color(ns: Theme.highlight)).frame(width: 7, height: 7)
                Text("\(friends.count) friend\(friends.count == 1 ? "" : "s") online").font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// The For You tab: discounted games outside the wishlist that fit its tags.
struct ForYouTab: View {
    @ObservedObject var store: Store
    @State private var keyText = ""

    /// Menus draw template images in the primary color whatever the style says, so the ✕ carries
    /// its own grey to match the + beside it.
    static let dismissIcon = icon("xmark.circle", "Dismiss")
    static let watchIcon = icon("plus.circle", "Watch")

    private static func icon(_ name: String, _ label: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: label)!.withSymbolConfiguration(config)!
        img.isTemplate = false
        return img
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Discounted games that fit your wishlist").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.isSuggesting {
                    ProgressView().controlSize(.mini)
                } else if let at = store.suggestions?.fetchedAt {
                    Text(Format.relative(at, now: store.now)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !store.hasAPIKey { keyCard }
            if store.visibleSuggestions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
                    Text(store.isSuggesting ? "Looking for games you'd like…" : "No suggestions right now. They're checked twice a day.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !store.isSuggesting {
                        Button("Check Now") { Task { await store.refreshSuggestions(force: true) } }.controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity).padding(14).card()
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(store.visibleSuggestions) { s in row(s) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Steam only shares owned games through the Web API, so offer the key right here.
    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Skip games you already own", systemImage: "key").font(.callout.weight(.medium))
            Text("Steam only shares your library through a Web API key. It's free and takes a minute; it also unlocks playtime and friends online.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                SecureField("Paste your key", text: $keyText).textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit { save() }
                Button("Save") { save() }.controlSize(.small).disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button("Get a key at steamcommunity.com/dev/apikey") { NSWorkspace.shared.open(Links.apiKey) }
                .buttonStyle(.link).font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func save() {
        let k = keyText.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        store.saveAPIKey(k)
        keyText = ""
    }

    private func row(_ s: Suggestion) -> some View {
        HStack(spacing: 10) {
            CapsuleArt(url: s.item.capsuleURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.item.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(detail(s)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let p = s.item.price {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("−\(p.discountPercent)%").font(.caption2.weight(.semibold)).lineLimit(1).fixedSize()
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color(ns: Theme.highlight).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(Color(ns: Theme.readable(Theme.highlight)))
                    Text(Format.price(p.finalCents, currency: p.currency)).font(.callout.weight(.medium)).monospacedDigit()
                }
                .fixedSize()
            }
            VStack(spacing: 4) {
                Button { store.watch(s.item, limitCents: nil) } label: { Image(nsImage: Self.watchIcon) }
                    .buttonStyle(.borderless)
                    .help("Watch \(s.item.name)")
                Menu {
                    Button("I Already Own This") { store.markOwned(s.id) }
                    Button("Not Interested") { store.dismissSuggestion(s.id) }
                } label: { Image(nsImage: Self.dismissIcon) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Already own it, or not interested")
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: DealRow.height)
        .card()
        .contentShape(Rectangle())
        .onTapGesture { SteamLink.open(s.item.storeURL) }
        .contextMenu {
            Button(SteamLink.opensInApp ? "Open in Steam" : "Open Store Page") { SteamLink.open(s.item.storeURL) }
            Button("Watch") { store.watch(s.item, limitCents: nil) }
            Divider()
            Button("I Already Own This") { store.markOwned(s.id) }
            Button("Not Interested") { store.dismissSuggestion(s.id) }
        }
    }

    private func detail(_ s: Suggestion) -> String {
        var parts: [String] = []
        let tags = store.tagNames(for: s)
        if !tags.isEmpty { parts.append(tags.joined(separator: ", ")) }
        if let r = s.item.reviews { parts.append("\(r.percentPositive)% positive") }
        return parts.joined(separator: " · ")
    }
}

/// Store search for watching any game, with an optional price limit per result.
struct AddGamePanel: View {
    @ObservedObject var store: Store
    var initialQuery = ""
    let close: () -> Void
    @State private var query = ""
    @State private var limitFor: AppID?
    @State private var limitText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Search the Steam store", text: $query).textFieldStyle(.plain).font(.callout)
                    .focused($searchFocused)
                if store.isSearching { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .card()
            Text("Watch any game, wishlisted or not. Set a limit to be notified the moment it's at or under that price.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let e = store.searchError {
                Text(e).font(.caption).foregroundStyle(.secondary)
            } else if query.trimmingCharacters(in: .whitespaces).count >= 2, !store.isSearching, store.searchResults.isEmpty {
                Text("No games match.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(10).card()
            }
            if !store.searchResults.isEmpty {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(store.searchResults.prefix(25)) { item in row(item) }
                    }
                }
                .frame(maxHeight: 6 * DealRow.height + 10)
                .fixedSize(horizontal: false, vertical: store.searchResults.count <= 6)
            }
        }
        .onChange(of: query) { _, q in store.search(q) }
        .onAppear {
            searchFocused = true
            if !initialQuery.isEmpty { query = initialQuery }
        }
    }

    private func row(_ item: StoreItem) -> some View {
        let watching = store.isWatching(item.appID)
        let limit = store.targets[item.appID]
        return HStack(spacing: 10) {
            CapsuleArt(url: item.capsuleURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(detail(item, watching: watching, limit: limit)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if limitFor == item.appID {
                TextField("Limit", text: $limitText, prompt: Text("Limit"))
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 58)
                    .onSubmit { commit(item) }
                Button("Watch") { commit(item) }.controlSize(.small).buttonStyle(.borderedProminent)
            } else {
                Button(watching ? (limit == nil ? "Set limit" : "Edit") : "Watch") {
                    limitText = limit.map { String(format: "%.2f", Double($0) / 100) } ?? ""
                    limitFor = item.appID
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: DealRow.height)
        .card()
    }

    private func detail(_ item: StoreItem, watching: Bool, limit: Int?) -> String {
        var parts: [String] = []
        if let p = item.price {
            parts.append(Format.price(p.finalCents, currency: p.currency) + (p.isOnSale ? " (−\(p.discountPercent)%)" : ""))
        } else {
            parts.append(item.isFree ? "Free or not for sale yet" : "No price")
        }
        if let limit, let cur = item.price?.currency { parts.append("limit \(Format.price(limit, currency: cur))") }
        if store.isOwned(item.appID) { parts.append("you own this") }
        else if store.isOnWishlist(item.appID) { parts.append("on wishlist") } else if watching { parts.append("watching") }
        return parts.joined(separator: " · ")
    }

    /// An empty limit watches for sales only; a price that doesn't parse leaves the field open.
    private func commit(_ item: StoreItem) {
        let trimmed = limitText.trimmingCharacters(in: .whitespaces)
        let cents = trimmed.isEmpty ? nil : Format.cents(parsing: trimmed)
        if !trimmed.isEmpty, cents == nil { return }
        store.watch(item, limitCents: cents)
        limitFor = nil
    }
}

/// Lays children out left to right, wrapping to new lines, so the chip row can grow.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: place(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, point) in zip(subviews, place(subviews, width: bounds.width).points) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (points, y + rowHeight)
    }
}

struct SetupCard: View {
    @ObservedObject var store: Store
    let openSettings: () -> Void
    var body: some View {
        let found = store.localAccounts.first
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect your Steam profile", systemImage: "person.crop.circle.badge.plus").font(.callout.weight(.medium))
            if let found {
                Text("Steam on this Mac is signed in as **\(found.displayName)**. Your wishlist must be public (Steam → Privacy → Game details) so the store can be checked without signing in.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Use \(found.displayName)") { store.useAccount(found) }.controlSize(.small).buttonStyle(.borderedProminent)
                    Button("Another account…") { openSettings() }.controlSize(.small)
                }
            } else {
                Text("Paste your profile URL or SteamID64 in Settings. Your wishlist must be public (Steam → Privacy → Game details) so the store can be checked without signing in.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { openSettings() }.controlSize(.small).buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
