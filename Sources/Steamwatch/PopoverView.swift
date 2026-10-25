import Charts
import SteamwatchCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: Store
    var openSettings: () -> Void

    @AppStorage(SettingsKey.dealFilter) private var filterRaw = DealFilter.all.rawValue
    @AppStorage(SettingsKey.dealSort) private var sortRaw = DealSort.best.rawValue
    @AppStorage(SettingsKey.showPlaytime) private var showPlaytime = true
    @AppStorage(SettingsKey.showFriends) private var showFriends = true
    @State private var query = ""
    @State private var editingTarget: AppID?

    /// Rows visible before the list scrolls.
    private let visibleRows = 6

    private var filter: DealFilter { DealFilter(rawValue: filterRaw) ?? .all }
    private var sort: DealSort { DealSort(rawValue: sortRaw) ?? .best }
    private var shown: [Deal] { sort.sorted(DealEngine.filter(store.deals, filter, query: query)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if store.needsSetup {
                SetupCard(openSettings: openSettings)
            } else {
                errorBanner
                if store.deals.count > visibleRows || !query.isEmpty || filter != .all || sort != .best { filterBar }
                dealsSection
                if showPlaytime { playtimeSection }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
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
        case 1: return "1 wishlist game on sale"
        default: return "\(store.deals.count) wishlist games on sale"
        }
    }

    private var subtitle: String {
        if store.needsSetup { return "Wishlist sale watcher" }
        var parts: [String] = []
        if let u = store.lastUpdated { parts.append("updated \(Format.relative(u, now: store.now))") }
        if store.wishlistCount > 0 { parts.append("\(store.wishlistCount) on wishlist") }
        if store.hidden.count > 0 { parts.append("\(store.hidden.count) hidden") }
        if store.staleCount > 0 { parts.append("\(store.staleCount) stale") }
        return parts.isEmpty ? (store.isRefreshing ? "Checking the store…" : "Wishlist sale watcher") : parts.joined(separator: " · ")
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
                ForEach(DealFilter.allCases) { f in
                    let count = DealEngine.filter(store.deals, f).count
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
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { deal in
                        DealRow(deal: deal, now: store.now, sort: sort, editing: editingTarget == deal.id,
                                beginEdit: { editingTarget = deal.id },
                                commit: { cents in store.setTarget(cents, for: deal.id); editingTarget = nil },
                                hide: { store.hide(deal.id) })
                    }
                }
            }
            .frame(maxHeight: CGFloat(visibleRows) * DealRow.height + CGFloat(visibleRows - 1) * 2)
            .fixedSize(horizontal: false, vertical: shown.count <= visibleRows)
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
            Link(destination: Links.wishlist) { Image(systemName: "heart") }.help("Open your wishlist")
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
    let editing: Bool
    let beginEdit: () -> Void
    let commit: (Int?) -> Void
    let hide: () -> Void
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
                    Text(detail).font(.caption).foregroundStyle(deal.meetsTarget ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // Badge and final price side by side, original price beneath: keeps the column narrow
            // so long names get the room.
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 5) {
                    Text("−\(deal.price.discountPercent)%")
                        .font(.caption2.weight(.semibold)).lineLimit(1).fixedSize()
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(deal.meetsTarget ? Color(ns: Theme.highlight) : Color(ns: Theme.highlight).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(deal.meetsTarget ? .white : accent)
                    Text(Format.price(deal.price.finalCents, currency: deal.price.currency)).font(.callout.weight(.medium)).monospacedDigit()
                }
                Text(Format.price(deal.price.originalCents, currency: deal.price.currency))
                    .font(.caption2).strikethrough().foregroundStyle(.tertiary).monospacedDigit()
            }
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .card(tint: deal.meetsTarget ? Color(ns: Theme.highlight) : nil)
        .contentShape(Rectangle())
        .onTapGesture { if !editing { openURL(deal.item.storeURL) } }
        .contextMenu {
            Button("Open Store Page") { openURL(deal.item.storeURL) }
            Divider()
            Button("Set Target to \(Format.price(deal.price.finalCents, currency: deal.price.currency))") { commit(deal.price.finalCents) }
            Button(deal.targetCents == nil ? "Set Target Price…" : "Change Target Price…") {
                text = deal.targetCents.map { String(format: "%.2f", Double($0) / 100) } ?? ""
                beginEdit()
            }
            if deal.targetCents != nil { Button("Clear Target") { commit(nil) } }
            Divider()
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
        if deal.priority > 0, deal.priority <= 30 { parts.append("#\(deal.priority) on wishlist") }
        if let ends = deal.price.saleEnds { parts.append("ends \(Format.saleEnds(ends, now: now))") }
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
        AsyncImage(url: Demo.isActive ? nil : url) { image in
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Played this week", systemImage: "gamecontroller").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Format.hours(week)).font(.callout.weight(.medium)).monospacedDigit()
                if let avg = store.playtime.weeklyAverageMinutes(now: store.now) {
                    Text("avg \(Format.hours(avg))").font(.caption2).foregroundStyle(.secondary)
                } else if store.twoWeekMinutes > 0 {
                    Text("\(Format.hours(store.twoWeekMinutes)) / 2 wk").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Chart(days) { day in
                BarMark(x: .value("Day", day.day, unit: .day), y: .value("Minutes", max(day.minutes, 2)))
                    .foregroundStyle(Calendar.current.isDateInToday(day.day) ? Color(ns: Theme.accent) : Color.secondary.opacity(0.35))
                    .cornerRadius(2)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: 32)
            if let top = store.playtime.mostPlayed(now: store.now) {
                Text("Most played: \(top.name) · \(Format.hours(top.minutes))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if let top = store.recentGames.max(by: { $0.minutesTwoWeeks < $1.minutesTwoWeeks }) {
                Text("Recent: \(top.name) · \(Format.hours(top.minutesTwoWeeks)) in 2 wk").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Daily bars fill in as Steamwatch keeps watching.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .card()
    }
}

struct FriendsMenu: View {
    let friends: [PlayerSummary]
    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu {
            ForEach(friends) { f in
                Button { openURL(f.profileURL) } label: {
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
    let openSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect your Steam profile", systemImage: "person.crop.circle.badge.plus").font(.callout.weight(.medium))
            Text("Paste your profile URL or SteamID64 in Settings. Your wishlist must be public (Steam → Privacy → Game details) so the store can be checked without signing in.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { openSettings() }.controlSize(.small).buttonStyle(.borderedProminent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
