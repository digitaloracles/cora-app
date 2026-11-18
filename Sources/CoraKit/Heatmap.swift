import Foundation

/// Daily usage of the person's agents: a year from `/app/v1/usage`, else the snapshot's own month.
public struct UsageHistory: Decodable, Sendable, Hashable {
    public struct Row: Decodable, Sendable, Hashable {
        public var agentId: String
        public var day: String
        public var tokensIn: Int
        public var tokensOut: Int
        public var turns: Int
        public var total: Int { tokensIn + tokensOut }

        enum CodingKeys: String, CodingKey { case agentId, day, tokensIn, tokensOut, turns }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            agentId = c.text(.agentId); day = c.text(.day)
            tokensIn = c.number(.tokensIn); tokensOut = c.number(.tokensOut); turns = c.number(.turns)
        }

        public init(agentId: String, day: String, tokensIn: Int, tokensOut: Int, turns: Int) {
            self.agentId = agentId; self.day = day; self.tokensIn = tokensIn; self.tokensOut = tokensOut; self.turns = turns
        }
    }

    public var today: String
    public var usage: [Row]

    enum CodingKeys: String, CodingKey { case today, usage }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        today = c.text(.today)
        usage = c.list(.usage)
    }

    public init(today: String, usage: [Row]) { self.today = today; self.usage = usage }

    /// What the snapshot already carries: 31 days per agent, today in the space's time zone.
    public init(snapshot: Snapshot) {
        today = Heatmap.dayKey(snapshot.generatedAt ?? Date(), timeZone: TimeZone(identifier: snapshot.timezone) ?? .current)
        usage = snapshot.agents.flatMap { agent in
            agent.usage.days.map { Row(agentId: agent.id, day: $0.day, tokensIn: $0.tokensIn, tokensOut: $0.tokensOut, turns: $0.turns) }
        }
    }

    /// Daily totals for one agent, or for everyone when `agentId` is nil.
    public func byDay(agentId: String? = nil) -> [String: Heatmap.Spent] {
        var totals: [String: Heatmap.Spent] = [:]
        for row in usage where agentId == nil || row.agentId == agentId {
            var spent = totals[row.day] ?? Heatmap.Spent(tokens: 0, turns: 0)
            spent.tokens += row.total
            spent.turns += row.turns
            totals[row.day] = spent
        }
        return totals
    }

    public func total(agentId: String? = nil) -> Int { usage.filter { agentId == nil || $0.agentId == agentId }.map(\.total).reduce(0, +) }
}

/// The panel's token heatmap: one square per day from the first recorded use to today, weeks as columns starting on
/// Monday, five levels relative to the busiest day (providers count tokens too differently for an absolute scale).
public struct Heatmap: Sendable, Hashable {
    public struct Spent: Sendable, Hashable {
        public var tokens: Int
        public var turns: Int
        public init(tokens: Int, turns: Int) { self.tokens = tokens; self.turns = turns }
    }

    public struct Cell: Sendable, Hashable, Identifiable {
        public var id: Int
        /// nil for the blank squares before the first day of the first week.
        public var day: String?
        public var date: Date?
        public var tokens: Int
        public var turns: Int
        public var level: Int
    }

    /// Columns of up to `rows` cells; the last one can be shorter.
    public var weeks: [[Cell]]
    public var rows: Int
    /// Month label by column, only where it has room (three columns from the previous one).
    public var months: [Int: Int]
    public var firstDay: String
    public var lastDay: String
    public var peak: Int

    public init?(byDay: [String: Spent], today: String) {
        guard let first = byDay.filter({ $0.key <= today && $0.value.tokens > 0 }).keys.min(),
              let start = Heatmap.date(first), let end = Heatmap.date(today) else { return nil }
        var days: [(key: String, date: Date)] = []
        var at = start
        while at <= end {
            days.append((Heatmap.dayKey(at, timeZone: Heatmap.utc), at))
            at = Heatmap.calendar.date(byAdding: .day, value: 1, to: at)!
        }
        let offset = (Heatmap.calendar.component(.weekday, from: start) + 5) % 7
        peak = max(1, days.map { byDay[$0.key]?.tokens ?? 0 }.max() ?? 1)
        rows = min(7, days.count + offset)
        firstDay = first; lastDay = today
        var cells: [Cell] = (0..<offset).map { Cell(id: $0, day: nil, date: nil, tokens: 0, turns: 0, level: -1) }
        var months: [Int: Int] = [:]
        var lastMonth = -1, labelled = -9
        for (index, day) in days.enumerated() {
            if index == 0 || (index + offset) % 7 == 0 {
                let column = (index + offset) / 7
                let month = Heatmap.calendar.component(.month, from: day.date) - 1
                if month != lastMonth && column - labelled >= 3 { months[column] = month; labelled = column }
                lastMonth = month
            }
            let spent = byDay[day.key]
            let tokens = spent?.tokens ?? 0
            cells.append(Cell(id: index + offset, day: day.key, date: day.date, tokens: tokens, turns: spent?.turns ?? 0, level: Heatmap.level(tokens, peak: peak)))
        }
        let height = rows
        weeks = stride(from: 0, to: cells.count, by: height).map { Array(cells[$0..<min($0 + height, cells.count)]) }
        self.months = months
    }

    /// Five steps, so a quiet day still shows against an empty one.
    public static func level(_ tokens: Int, peak: Int) -> Int {
        tokens <= 0 ? 0 : min(4, 1 + Int((Double(tokens) / Double(max(1, peak)) * 3.999).rounded(.down)))
    }

    static let utc = TimeZone(identifier: "UTC")!
    static let calendar: Calendar = { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc; return calendar }()

    public static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: timeZone, formatOptions: [.withFullDate])
    }

    /// Noon UTC of a `yyyy-MM-dd` day, so no daylight saving change moves it.
    public static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}
