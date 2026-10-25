import Foundation

public enum Format {
    /// Locale for prices. The user's own by default; tests pin it, because the symbol depends on it
    /// ("$11.99" in en_US, "US$11.99" in a bare POSIX locale such as a Linux CI container).
    public static var locale: Locale = .current

    /// "$11.99", "€11,99"; falls back to "11.99 USD" where the locale can't format the currency.
    public static func price(_ cents: Int, currency: String) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .currency
        f.currencyCode = currency
        let amount = Double(cents) / 100
        if let s = f.string(from: NSNumber(value: amount)) { return s }
        return String(format: "%.2f %@", amount, currency)
    }

    /// "45m", "11.4h", "25h", "120h".
    public static func hours(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = Double(minutes) / 60
        if h >= 100 { return "\(Int(h.rounded()))h" }
        let s = String(format: "%.1f", h)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "h"
    }

    /// "840", "12k", "1.2M".
    public static func compact(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<10_000: return String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k")
        case ..<1_000_000: return "\(n / 1000)k"
        default: return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }

    /// "just now", "12 min ago", "3 h ago", "2 d ago".
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(s / 60) min ago"
        case ..<86_400: return "\(s / 3600) h ago"
        default: return "\(s / 86_400) d ago"
        }
    }

    /// "in 2d", "in 5h", "soon".
    public static func saleEnds(_ date: Date, now: Date = Date()) -> String {
        let s = Int(date.timeIntervalSince(now))
        switch s {
        case ..<3600: return "soon"
        case ..<86_400: return "in \(s / 3600)h"
        default: return "in \(s / 86_400)d"
        }
    }

    /// Parses what a user types into a target-price field: "15", "14.99", "$14.99", "14,99".
    public static func cents(parsing text: String) -> Int? {
        let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "," }.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value >= 0 else { return nil }
        return Int((value * 100).rounded())
    }
}
