import Foundation

/// A timestamp Cora sends either as ISO 8601 text or as Unix milliseconds.
public struct Instant: Codable, Hashable, Sendable {
    public let date: Date

    public init(_ date: Date) { self.date = date }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let millis = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: millis > 1e12 ? millis / 1000 : millis)
            return
        }
        let text = try container.decode(String.self)
        guard let parsed = Instant.parse(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date \(text)")
        }
        date = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Instant.format(date))
    }

    public static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension KeyedDecodingContainer {
    func instant(_ key: Key) -> Date? {
        guard let text = try? decodeIfPresent(String.self, forKey: key), !text.isEmpty else {
            if let millis = try? decodeIfPresent(Double.self, forKey: key) { return Date(timeIntervalSince1970: millis / 1000) }
            return nil
        }
        return Instant.parse(text)
    }

    func text(_ key: Key) -> String { (try? decodeIfPresent(String.self, forKey: key)) ?? "" }
    func flag(_ key: Key) -> Bool { (try? decodeIfPresent(Bool.self, forKey: key)) ?? false }
    func number(_ key: Key) -> Int { (try? decodeIfPresent(Int.self, forKey: key)) ?? Int((try? decodeIfPresent(Double.self, forKey: key)) ?? 0) }
    func list<T: Decodable>(_ key: Key) -> [T] { (try? decodeIfPresent([Lenient<T>].self, forKey: key))?.compactMap(\.value) ?? [] }
}

/// Decodes an element of a list without failing the whole list: newer servers may add kinds older apps do not know.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

public struct Snapshot: Decodable, Sendable {
    public var version: Int
    public var generatedAt: Date?
    public var timezone: String
    public var space: Space
    public var user: User
    public var accounts: [Account]
    public var agents: [Agent]
    /// Plans across every thread; nil from servers that do not list them yet.
    public var plans: PlanBoard?
    /// Questions agents asked with answers to choose from, newest first; empty from servers that do not list them yet.
    public var requests: [ChoiceRequest]

    public struct Space: Decodable, Sendable, Hashable {
        public var name: String
        public var origin: String
        public init(name: String, origin: String) { self.name = name; self.origin = origin }
    }

    public struct User: Decodable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var email: String
        public var role: String
        public init(id: String, name: String, email: String, role: String) { self.id = id; self.name = name; self.email = email; self.role = role }
    }

    enum CodingKeys: String, CodingKey { case version, generatedAt, timezone, space, user, accounts, agents, plans, requests }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.number(.version)
        generatedAt = c.instant(.generatedAt)
        timezone = c.text(.timezone)
        space = try c.decode(Space.self, forKey: .space)
        user = try c.decode(User.self, forKey: .user)
        accounts = c.list(.accounts)
        agents = c.list(.agents)
        plans = try? c.decodeIfPresent(PlanBoard.self, forKey: .plans)
        requests = c.list(.requests)
    }

    public init(version: Int = 1, generatedAt: Date? = Date(), timezone: String = "Europe/Rome", space: Space, user: User, accounts: [Account], agents: [Agent], plans: PlanBoard? = nil, requests: [ChoiceRequest] = []) {
        self.version = version; self.generatedAt = generatedAt; self.timezone = timezone; self.space = space; self.user = user; self.accounts = accounts; self.agents = agents; self.plans = plans; self.requests = requests
    }

    /// The open plans of one agent.
    public func openPlans(of agentId: String) -> [Plan] { (plans?.open ?? []).filter { $0.agentId == agentId } }

    public func agent(_ id: String) -> Agent? { agents.first { $0.id == id } }
    public func accounts(of agent: Agent) -> [Account] { accounts.filter { agent.accountIds.contains($0.id) } }
    public var working: [Agent] { agents.filter { $0.state == .working } }

    /// The account-wide window closest to its limit, for the menu bar.
    public var tightest: (account: Account, window: QuotaWindow)? {
        accounts.compactMap { account in account.tightestWindow.map { (account, $0) } }.max { $0.1.usedPercent < $1.1.usedPercent }
    }
}

public struct Account: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var provider: String
    public var label: String
    public var email: String
    public var plan: String
    public var status: String
    public var server: Bool
    public var usage: QuotaUsage?
    public var agentIds: [String]

    enum CodingKeys: String, CodingKey { case id, provider, label, email, plan, status, server, usage, agentIds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = c.text(.provider)
        label = c.text(.label)
        email = c.text(.email)
        plan = c.text(.plan)
        status = c.text(.status)
        server = c.flag(.server)
        usage = try? c.decodeIfPresent(QuotaUsage.self, forKey: .usage)
        agentIds = (try? c.decodeIfPresent([String].self, forKey: .agentIds)) ?? []
    }

    public init(id: String, provider: String, label: String, email: String = "", plan: String = "", status: String = "ready", server: Bool = false, usage: QuotaUsage?, agentIds: [String]) {
        self.id = id; self.provider = provider; self.label = label; self.email = email; self.plan = plan; self.status = status; self.server = server; self.usage = usage; self.agentIds = agentIds
    }

    public var displayName: String { label.isEmpty ? Providers.name(provider) : label }

    /// Account-wide windows only: a model-scoped limit does not stop the whole account.
    public var tightestWindow: QuotaWindow? {
        (usage?.windows ?? []).filter { $0.group.isEmpty }.max { $0.usedPercent < $1.usedPercent }
    }

    /// The account-wide windows the row shows, shortest first: the 5-hour session above the week or the month.
    /// Two at most; every window, model-scoped ones included, is in the expanded view.
    public var mainWindows: [QuotaWindow] {
        Array((usage?.windows ?? []).filter { $0.group.isEmpty }.sorted { $0.span < $1.span }.prefix(2))
    }

    /// Every window, account-wide ones first, each group by length.
    public var allWindows: [QuotaWindow] {
        (usage?.windows ?? []).sorted { ($0.group.isEmpty ? 0 : 1, $0.group, $0.span) < ($1.group.isEmpty ? 0 : 1, $1.group, $1.span) }
    }

    /// What is left on a pay-as-you-go account (DeepSeek): the total balance, or the first one the provider reports.
    /// Nothing when the account must sign in again: the last balance would no longer be true.
    public var balance: Balance? {
        guard usage?.issue != "AUTH_REQUIRED" else { return nil }
        let list = usage?.balances ?? []
        return list.first { $0.kind == "total" } ?? list.first
    }
}

public struct QuotaUsage: Decodable, Sendable, Hashable {
    public var state: String
    public var windows: [QuotaWindow]
    public var balances: [Balance]
    public var fetchedAt: Date?
    public var issue: String?
    public var stale: Bool

    enum CodingKeys: String, CodingKey { case state, windows, balances, fetchedAt, issue, stale }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = c.text(.state)
        windows = c.list(.windows)
        balances = c.list(.balances)
        fetchedAt = c.instant(.fetchedAt)
        issue = try? c.decodeIfPresent(String.self, forKey: .issue)
        stale = c.flag(.stale)
    }

    public init(state: String = "ready", windows: [QuotaWindow], balances: [Balance] = [], fetchedAt: Date? = Date(), issue: String? = nil, stale: Bool = false) {
        self.state = state; self.windows = windows; self.balances = balances; self.fetchedAt = fetchedAt; self.issue = issue; self.stale = stale
    }
}

public struct QuotaWindow: Decodable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case session, weekly, monthly, custom }
    public var id: String
    public var kind: Kind
    public var group: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var minutes: Int?

    enum CodingKeys: String, CodingKey { case id, kind, group, usedPercent, resetsAt, minutes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = Kind(rawValue: c.text(.kind)) ?? .custom
        group = c.text(.group)
        usedPercent = (try? c.decode(Double.self, forKey: .usedPercent)) ?? 0
        resetsAt = c.instant(.resetsAt)
        minutes = try? c.decodeIfPresent(Int.self, forKey: .minutes)
    }

    public init(id: String, kind: Kind, group: String = "", usedPercent: Double, resetsAt: Date?, minutes: Int? = nil) {
        self.id = id; self.kind = kind; self.group = group; self.usedPercent = usedPercent; self.resetsAt = resetsAt; self.minutes = minutes
    }

    public var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// How long the window lasts, in minutes, to put the shorter one first.
    public var span: Int {
        if let minutes, minutes > 0 { return minutes }
        switch kind {
        case .session: return 300
        case .weekly: return 10_080
        case .monthly: return 43_200
        case .custom: return Int.max
        }
    }

    /// The window's length as a short tag next to its figures: `5h`, `24h`, `7d`, `30d` (`7g` in Italian).
    public func tag(italian: Bool = Format.italian) -> String {
        let day = italian ? "g" : "d"
        switch kind {
        case .weekly where minutes == nil: return "7\(day)"
        case .monthly where minutes == nil: return "30\(day)"
        default:
            let length = span
            if length == Int.max { return "–" }
            if length <= 2_880 { return "\(max(1, length / 60))h" }
            return "\(length / 1_440)\(day)"
        }
    }
    public var level: Level { remainingPercent <= 5 ? .critical : remainingPercent <= 20 ? .warning : .normal }

    public enum Level: Sendable { case normal, warning, critical }
}

public struct Balance: Decodable, Sendable, Hashable {
    public var kind: String
    public var currency: String
    public var amount: String

    public init(kind: String, currency: String, amount: String) { self.kind = kind; self.currency = currency; self.amount = amount }

    public var value: Double { Double(amount) ?? 0 }
    public var isEmpty: Bool { value <= 0 }
    /// `$14.90`, or `14,90 USD` in Italian.
    public var text: String { Format.money(amount, currency: currency) }
}

public struct Tokens: Decodable, Sendable, Hashable {
    public var tokensIn: Int
    public var tokensOut: Int
    public var turns: Int
    public var total: Int { tokensIn + tokensOut }

    enum CodingKeys: String, CodingKey { case tokensIn, tokensOut, turns }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokensIn = c.number(.tokensIn); tokensOut = c.number(.tokensOut); turns = c.number(.turns)
    }

    public init(tokensIn: Int, tokensOut: Int, turns: Int) { self.tokensIn = tokensIn; self.tokensOut = tokensOut; self.turns = turns }
    public static let zero = Tokens(tokensIn: 0, tokensOut: 0, turns: 0)
}

public struct DayTokens: Decodable, Sendable, Hashable, Identifiable {
    public var day: String
    public var tokensIn: Int
    public var tokensOut: Int
    public var turns: Int
    public var id: String { day }
    public var total: Int { tokensIn + tokensOut }
}

public struct AgentUsage: Decodable, Sendable, Hashable {
    public var today: Tokens
    public var week: Tokens
    public var month: Tokens
    public var days: [DayTokens]

    enum CodingKeys: String, CodingKey { case today, week, month, days }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        today = (try? c.decode(Tokens.self, forKey: .today)) ?? .zero
        week = (try? c.decode(Tokens.self, forKey: .week)) ?? .zero
        month = (try? c.decode(Tokens.self, forKey: .month)) ?? .zero
        days = c.list(.days)
    }

    public init(today: Tokens, week: Tokens, month: Tokens, days: [DayTokens]) { self.today = today; self.week = week; self.month = month; self.days = days }
}

public struct Agent: Decodable, Sendable, Identifiable, Hashable {
    public enum State: String, Sendable { case working, listening, idle, off }

    public var id: String
    public var name: String
    public var color: String
    public var enabled: Bool
    public var model: String
    public var avatar: String
    public var state: State
    public var accountIds: [String]
    public var usage: AgentUsage
    public var live: [LiveTrace]
    public var threads: [ThreadInfo]

    enum CodingKeys: String, CodingKey { case id, name, color, enabled, model, avatar, state, accountIds, usage, live, threads }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.text(.name)
        color = c.text(.color)
        enabled = c.flag(.enabled)
        model = c.text(.model)
        avatar = c.text(.avatar)
        state = State(rawValue: c.text(.state)) ?? .idle
        accountIds = (try? c.decodeIfPresent([String].self, forKey: .accountIds)) ?? []
        usage = (try? c.decode(AgentUsage.self, forKey: .usage)) ?? AgentUsage(today: .zero, week: .zero, month: .zero, days: [])
        live = c.list(.live)
        threads = c.list(.threads)
    }

    public init(id: String, name: String, color: String, enabled: Bool = true, model: String, avatar: String = "", state: State, accountIds: [String], usage: AgentUsage, live: [LiveTrace] = [], threads: [ThreadInfo] = []) {
        self.id = id; self.name = name; self.color = color; self.enabled = enabled; self.model = model; self.avatar = avatar; self.state = state; self.accountIds = accountIds; self.usage = usage; self.live = live; self.threads = threads
    }
}

public struct LiveTrace: Decodable, Sendable, Hashable, Identifiable {
    public var traceId: String
    public var kind: String
    public var channelId: String
    public var threadName: String
    public var link: String
    public var startedAt: Date?
    public var model: String
    public var goal: String
    public var tokensIn: Int
    public var tokensOut: Int
    public var stepCount: Int
    public var lastStep: Step?
    public var id: String { traceId }

    enum CodingKeys: String, CodingKey { case traceId, kind, channelId, threadName, link, startedAt, model, goal, tokensIn, tokensOut, stepCount, lastStep }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        traceId = try c.decode(String.self, forKey: .traceId)
        kind = c.text(.kind); channelId = c.text(.channelId); threadName = c.text(.threadName); link = c.text(.link)
        startedAt = c.instant(.startedAt); model = c.text(.model); goal = c.text(.goal)
        tokensIn = c.number(.tokensIn); tokensOut = c.number(.tokensOut); stepCount = c.number(.stepCount)
        lastStep = try? c.decodeIfPresent(Step.self, forKey: .lastStep)
    }

    public init(traceId: String, kind: String = "chat", channelId: String, threadName: String, link: String = "", startedAt: Date?, model: String = "", goal: String = "", tokensIn: Int, tokensOut: Int, stepCount: Int, lastStep: Step?) {
        self.traceId = traceId; self.kind = kind; self.channelId = channelId; self.threadName = threadName; self.link = link; self.startedAt = startedAt; self.model = model; self.goal = goal; self.tokensIn = tokensIn; self.tokensOut = tokensOut; self.stepCount = stepCount; self.lastStep = lastStep
    }
}

public struct ThreadInfo: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String
    public var link: String
    public var open: Bool
    public var listening: Bool
    public var status: String
    public var lastAt: Date?
    public var traceId: String
    public var reasoning: String
    public var tokensIn: Int
    public var tokensOut: Int

    enum CodingKeys: String, CodingKey { case id, name, kind, link, open, listening, status, lastAt, traceId, reasoning, tokensIn, tokensOut }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.text(.name); kind = c.text(.kind); link = c.text(.link)
        open = c.flag(.open); listening = c.flag(.listening); status = c.text(.status)
        lastAt = c.instant(.lastAt); traceId = c.text(.traceId); reasoning = c.text(.reasoning)
        tokensIn = c.number(.tokensIn); tokensOut = c.number(.tokensOut)
    }

    public init(id: String, name: String, kind: String = "discord", link: String = "", open: Bool = true, listening: Bool = true, status: String, lastAt: Date?, traceId: String = "", reasoning: String, tokensIn: Int = 0, tokensOut: Int = 0) {
        self.id = id; self.name = name; self.kind = kind; self.link = link; self.open = open; self.listening = listening; self.status = status; self.lastAt = lastAt; self.traceId = traceId; self.reasoning = reasoning; self.tokensIn = tokensIn; self.tokensOut = tokensOut
    }
}

/// One thing an agent did in a turn: a thought, a tool call with its result, text it wrote, or a note from Cora.
public struct Step: Decodable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case thinking, text, tool, note, other }
    public var kind: Kind
    public var at: Date?
    public var name: String
    public var text: String
    public var args: String
    public var result: String
    public var id: String { "\(at?.timeIntervalSince1970 ?? 0)-\(kind.rawValue)-\(name)-\(text.prefix(40))" }

    enum CodingKeys: String, CodingKey { case type, at, name, text, args, result }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = Kind(rawValue: c.text(.type)) ?? .other
        at = c.instant(.at)
        name = c.text(.name)
        text = c.text(.text)
        result = c.text(.result)
        if let raw = try? c.decodeIfPresent(JSONValue.self, forKey: .args) { args = raw.compact } else { args = "" }
    }

    public init(kind: Kind, at: Date?, name: String = "", text: String = "", args: String = "", result: String = "") {
        self.kind = kind; self.at = at; self.name = name; self.text = text; self.args = args; self.result = result
    }

    /// What a list shows for this step in one line.
    public var headline: String { kind == .tool ? name : text }
}

public struct TraceDetail: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var agentId: String
    public var agentName: String
    public var kind: String
    public var channelId: String
    public var model: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var status: String
    public var tokensIn: Int
    public var tokensOut: Int
    public var goal: String
    public var output: String
    public var error: String
    public var steps: [Step]

    enum CodingKeys: String, CodingKey { case id, agentId, agentName, kind, channelId, model, startedAt, endedAt, status, tokensIn, tokensOut, goal, output, error, steps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentId = c.text(.agentId); agentName = c.text(.agentName); kind = c.text(.kind); channelId = c.text(.channelId); model = c.text(.model)
        startedAt = c.instant(.startedAt); endedAt = c.instant(.endedAt); status = c.text(.status)
        tokensIn = c.number(.tokensIn); tokensOut = c.number(.tokensOut); goal = c.text(.goal); output = c.text(.output); error = c.text(.error)
        steps = c.list(.steps)
    }

    public init(id: String, agentId: String, agentName: String = "", kind: String = "chat", channelId: String = "", model: String = "", startedAt: Date?, endedAt: Date? = nil, status: String, tokensIn: Int = 0, tokensOut: Int = 0, goal: String = "", output: String = "", error: String = "", steps: [Step]) {
        self.id = id; self.agentId = agentId; self.agentName = agentName; self.kind = kind; self.channelId = channelId; self.model = model; self.startedAt = startedAt; self.endedAt = endedAt; self.status = status; self.tokensIn = tokensIn; self.tokensOut = tokensOut; self.goal = goal; self.output = output; self.error = error; self.steps = steps
    }
}

public struct ThreadDetail: Decodable, Sendable {
    public var thread: Thread
    public var traces: [TraceDetail]

    public struct Thread: Decodable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var link: String

        enum CodingKeys: String, CodingKey { case id, name, link }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id); name = c.text(.name); link = c.text(.link)
        }
    }

    enum CodingKeys: String, CodingKey { case thread, traces }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thread = try c.decode(Thread.self, forKey: .thread)
        traces = c.list(.traces)
    }
}

/// Any JSON, kept only to show tool arguments.
public enum JSONValue: Decodable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public var compact: String {
        switch self {
        case .string(let value): return "\"\(value)\""
        case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let values): return "[" + values.map(\.compact).joined(separator: ", ") + "]"
        case .object(let fields): return "{" + fields.keys.sorted().map { "\($0): \(fields[$0]!.compact)" }.joined(separator: ", ") + "}"
        }
    }
}

public enum Providers {
    public static func name(_ provider: String) -> String {
        switch provider {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "grok": return "Grok"
        case "muse": return "Muse Code"
        case "gemini": return "Gemini"
        case "kimi": return "Kimi"
        case "ollama": return "Ollama Cloud"
        case "deepseek": return "DeepSeek"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }
}

extension Agent {
    /// Every word of the query must appear in the agent's name, its model, what it is working on or its threads.
    public static func matching(_ list: [Agent], _ query: String) -> [Agent] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return list }
        return list.filter { agent in
            let text = ([agent.name, agent.model] + agent.live.flatMap { [$0.threadName, $0.goal] } + agent.threads.map(\.name)).joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

/// The plans an agent keeps in a thread: a checklist done in order, open (active or blocked) or finished (completed or closed).
public struct Plan: Decodable, Sendable, Identifiable, Hashable {
    public enum Status: String, Sendable { case active, blocked, completed, closed }

    public struct Item: Decodable, Sendable, Identifiable, Hashable {
        public var id: String
        public var text: String
        public init(id: String, text: String) { self.id = id; self.text = text }
    }

    /// A checklist item with reasoning linked to it, and how many steps.
    public struct Reasoned: Decodable, Sendable, Identifiable, Hashable {
        public var id: String
        public var text: String
        public var count: Int

        enum CodingKeys: String, CodingKey { case id, text, count }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id); text = c.text(.text); count = c.number(.count)
        }
        public init(id: String, text: String, count: Int) { self.id = id; self.text = text; self.count = count }
    }

    public var id: String
    public var agentId: String
    public var agentName: String
    public var color: String
    public var channelId: String
    public var threadName: String
    public var link: String
    public var name: String
    public var status: Status
    public var items: [Item]
    public var done: Int
    public var blockedReason: String
    public var updatedAt: Date?
    public var tasks: [Reasoned]

    enum CodingKeys: String, CodingKey { case id, agentId, agentName, color, channelId, threadName, link, name, status, items, done, blockedReason, updatedAt, tasksWithReasoning }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentId = c.text(.agentId); agentName = c.text(.agentName); color = c.text(.color); channelId = c.text(.channelId)
        threadName = c.text(.threadName); link = c.text(.link); name = c.text(.name)
        guard let status = Status(rawValue: c.text(.status)) else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "Unknown plan status")
        }
        self.status = status
        items = c.list(.items); done = c.number(.done); blockedReason = c.text(.blockedReason)
        updatedAt = c.instant(.updatedAt); tasks = c.list(.tasksWithReasoning)
    }

    public init(id: String, agentId: String, agentName: String, color: String = "", channelId: String, threadName: String, link: String = "", name: String, status: Status, items: [Item], done: Int, blockedReason: String = "", updatedAt: Date?, tasks: [Reasoned] = []) {
        self.id = id; self.agentId = agentId; self.agentName = agentName; self.color = color; self.channelId = channelId; self.threadName = threadName; self.link = link; self.name = name
        self.status = status; self.items = items; self.done = done; self.blockedReason = blockedReason; self.updatedAt = updatedAt; self.tasks = tasks
    }

    public var isOpen: Bool { status == .active || status == .blocked }
    /// 0 to 1, what share of the checklist is done.
    public var progress: Double { items.isEmpty ? 0 : Double(min(done, items.count)) / Double(items.count) }
    /// The item the agent works on now: the first not done, while the plan is open.
    public var current: Item? { isOpen && done < items.count ? items[done] : nil }
    public func reasoned(_ item: Item) -> Reasoned? { tasks.first { $0.id == item.id } }
    public enum ItemState: Sendable { case done, current, blocked, pending, dropped }
    public func state(of index: Int) -> ItemState {
        if index < done { return .done }
        if index == done && isOpen { return status == .blocked ? .blocked : .current }
        return status == .closed ? .dropped : .pending
    }
}

/// The snapshot's plans: every open one, the latest finished ones and the cursor for older history.
public struct PlanBoard: Decodable, Sendable, Hashable {
    public var open: [Plan]
    public var history: [Plan]
    public var next: String?

    enum CodingKeys: String, CodingKey { case open, history, next }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        open = c.list(.open); history = c.list(.history)
        next = try? c.decodeIfPresent(String.self, forKey: .next)
    }
    public init(open: [Plan], history: [Plan], next: String? = nil) { self.open = open; self.history = history; self.next = next }
}

/// A page of plans from `/app/v1/plans`.
public struct PlanPage: Decodable, Sendable {
    public var plans: [Plan]
    public var next: String?

    enum CodingKeys: String, CodingKey { case plans, next }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plans = c.list(.plans); next = try? c.decodeIfPresent(String.self, forKey: .next)
    }
}

/// The reasoning linked to one checklist item, newest first, paged by `next`.
public struct PlanTaskReasoning: Decodable, Sendable {
    public struct Event: Decodable, Sendable, Identifiable, Hashable {
        public var seq: Int
        public var traceId: String
        public var step: Step
        public var id: Int { seq }
    }
    public var events: [Event]
    public var next: Int?

    enum CodingKeys: String, CodingKey { case events, next }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = c.list(.events); next = try? c.decodeIfPresent(Int.self, forKey: .next)
    }
}

/// A question an agent asked with answers to choose from: pressing one answers it as the button in the chat would.
public struct ChoiceRequest: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var agentId: String
    public var agentName: String
    public var color: String
    public var channelId: String
    public var threadName: String
    public var link: String
    public var question: String
    public var choices: [String]
    public var askedAt: Date?

    enum CodingKeys: String, CodingKey { case id, agentId, agentName, color, channelId, threadName, link, question, choices, askedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agentId = c.text(.agentId); agentName = c.text(.agentName); color = c.text(.color); channelId = c.text(.channelId)
        threadName = c.text(.threadName); link = c.text(.link); question = c.text(.question)
        choices = (try? c.decodeIfPresent([String].self, forKey: .choices)) ?? []
        askedAt = c.instant(.askedAt)
    }
    public init(id: String, agentId: String, agentName: String, color: String = "#f2a93b", channelId: String, threadName: String = "", link: String = "", question: String, choices: [String], askedAt: Date? = Date()) {
        self.id = id; self.agentId = agentId; self.agentName = agentName; self.color = color; self.channelId = channelId
        self.threadName = threadName; self.link = link; self.question = question; self.choices = choices; self.askedAt = askedAt
    }
}

/// What the space answered when one of the choices was pressed.
public struct ChoiceAnswer: Decodable, Sendable { public var id: String; public var answer: String }
