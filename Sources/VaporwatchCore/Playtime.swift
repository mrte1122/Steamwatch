import Foundation

/// Steam only reports "minutes in the last two weeks" per game, never per day. Sampling that number
/// on every refresh and attributing each increase to the day it was noticed gives a daily chart
/// that is exact to within one refresh interval (as long as the app was running).
public struct PlaytimeSample: Codable, Equatable, Sendable {
    public let date: Date
    /// Two-week minutes per app, keyed by appID as a string (see PriceHistory for why).
    public let minutes: [String: Int]
    public let names: [String: String]

    public init(date: Date, games: [RecentGame]) {
        self.date = date
        minutes = Dictionary(games.map { (String($0.appID), $0.minutesTwoWeeks) }, uniquingKeysWith: { a, _ in a })
        names = Dictionary(games.map { (String($0.appID), $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    public var total: Int { minutes.values.reduce(0, +) }
}

public struct DayPlaytime: Equatable, Sendable, Identifiable {
    public let day: Date
    public let minutes: Int
    public var id: Date { day }
}

public struct PlaytimeLog: Codable, Equatable, Sendable {
    public var samples: [PlaytimeSample]

    public init(samples: [PlaytimeSample] = []) { self.samples = samples }

    public var latest: PlaytimeSample? { samples.last }

    /// Append a reading when something changed (or six hours passed, to keep the series anchored),
    /// and drop samples older than three weeks: nothing past that can affect a 7-day view.
    public mutating func record(_ games: [RecentGame], at now: Date = Date()) {
        let sample = PlaytimeSample(date: now, games: games)
        if let last = samples.last, last.minutes == sample.minutes, now.timeIntervalSince(last.date) < 6 * 3600 { return }
        samples.append(sample)
        let cutoff = now.addingTimeInterval(-21 * 86_400)
        samples.removeAll { $0.date < cutoff }
    }

    /// Minutes played on each of the last `days` calendar days (oldest first, today last).
    public func daily(days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> [DayPlaytime] {
        let today = calendar.startOfDay(for: now)
        var buckets: [Date: Int] = [:]
        for (a, b) in zip(samples, samples.dropFirst()) {
            let day = calendar.startOfDay(for: b.date)
            buckets[day, default: 0] += gained(from: a, to: b).values.reduce(0, +)
        }
        return (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { DayPlaytime(day: $0, minutes: buckets[$0] ?? 0) }
        }
    }

    /// Minutes seen accumulating over the last 7 days of samples (0 until there are two samples).
    public func weekMinutes(now: Date = Date(), calendar: Calendar = .current) -> Int {
        daily(days: 7, now: now, calendar: calendar).reduce(0) { $0 + $1.minutes }
    }

    /// Average over the previous four complete weeks of data, for the "avg" caption; nil until
    /// there's at least a week of samples.
    public func weeklyAverageMinutes(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let first = samples.first, now.timeIntervalSince(first.date) >= 7 * 86_400 else { return nil }
        let days = daily(days: 21, now: now, calendar: calendar).dropLast(7)
        let covered = min(14.0, now.timeIntervalSince(first.date) / 86_400 - 7)
        guard covered >= 1 else { return nil }
        return Int(Double(days.reduce(0) { $0 + $1.minutes }) / covered * 7)
    }

    /// The game with the most minutes gained in the last `days` days.
    public func mostPlayed(days: Int = 7, now: Date = Date()) -> (name: String, minutes: Int)? {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var totals: [String: Int] = [:]
        var names: [String: String] = [:]
        for (a, b) in zip(samples, samples.dropFirst()) where b.date >= cutoff {
            for (app, m) in gained(from: a, to: b) { totals[app, default: 0] += m; names[app] = b.names[app] ?? a.names[app] }
        }
        guard let top = totals.max(by: { $0.value < $1.value }), top.value > 0 else { return nil }
        return (names[top.key] ?? "App \(top.key)", top.value)
    }

    /// Per-app minutes that appeared between two samples. The two-week window also *loses* minutes
    /// as old sessions age out, so only increases count.
    private func gained(from a: PlaytimeSample, to b: PlaytimeSample) -> [String: Int] {
        var out: [String: Int] = [:]
        for (app, m) in b.minutes {
            let d = m - (a.minutes[app] ?? 0)
            if d > 0 { out[app] = d }
        }
        return out
    }
}
