import Foundation

public enum Format {
    public static var italian: Bool { (Locale.preferredLanguages.first ?? "en").hasPrefix("it") }

    /// `950`, `45.2k`, `1.25M`, `3.1B`.
    public static func tokens(_ value: Int) -> String {
        let number = Double(value)
        func trim(_ text: String) -> String { text.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }
        switch number {
        case ..<1_000: return String(value)
        case ..<100_000: return trim(String(format: "%.1f", number / 1_000)) + "k"
        case ..<1_000_000: return String(format: "%.0f", number / 1_000) + "k"
        case ..<1_000_000_000: return trim(String(format: "%.2f", number / 1_000_000)) + "M"
        default: return trim(String(format: "%.1f", number / 1_000_000_000)) + "B"
        }
    }

    /// `12m`, `2h 10m`, `3d 4h` (`3g 4h` in Italian).
    public static func countdown(to date: Date, from now: Date = Date(), italian: Bool = Format.italian) -> String {
        let minutes = max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        let day = italian ? "g" : "d"
        if minutes >= 1440 { return "\(minutes / 1440)\(day) \(minutes % 1440 / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    /// `now`, `3 min ago`, `2 h ago`, `3d 4h ago`.
    public static func ago(_ date: Date, from now: Date = Date(), italian: Bool = Format.italian) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 45 { return italian ? "ora" : "now" }
        let minutes = seconds / 60
        if minutes < 60 { return italian ? "\(max(1, minutes)) min fa" : "\(max(1, minutes)) min ago" }
        if minutes < 1440 { return italian ? "\(minutes / 60) h fa" : "\(minutes / 60) h ago" }
        let day = italian ? "g" : "d"
        return italian ? "\(minutes / 1440)\(day) \(minutes % 1440 / 60)h fa" : "\(minutes / 1440)\(day) \(minutes % 1440 / 60)h ago"
    }

    /// `1:05` while a turn runs, `12:40` past an hour.
    public static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    public static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// An amount the provider sends as a decimal string, with its currency: `$14.90`, `14,90 USD`.
    public static func money(_ amount: String, currency: String, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        guard let number = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else { return "\(amount) \(currency)" }
        return formatter.string(from: number as NSDecimalNumber) ?? "\(amount) \(currency)"
    }

    /// The model id without its harness: `claude/claude-opus-5-5` → `claude-opus-5-5`.
    public static func model(_ id: String) -> String { id.split(separator: "/").last.map(String.init) ?? id }
}
