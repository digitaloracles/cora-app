import CoraKit
import Foundation

/// Sample data for previews and screenshots.
enum Samples {
    static let now = Date()

    static func days(_ base: Int) -> [DayTokens] {
        (0..<30).map { index in
            let date = Calendar.current.date(byAdding: .day, value: index - 29, to: now)!
            let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
            let wave = Int((sin(Double(index) / 3) + 1.3) * Double(base) * (index % 6 == 5 ? 0.3 : 1))
            return try! JSONDecoder().decode(DayTokens.self, from: Data(#"{"day":"\#(day)","tokensIn":\#(wave * 4 / 5),"tokensOut":\#(wave / 5),"turns":\#(max(1, wave / 9000))}"#.utf8))
        }
    }

    static func usage(_ base: Int) -> AgentUsage {
        let list = days(base)
        let sum = { (slice: ArraySlice<DayTokens>) in Tokens(tokensIn: slice.map(\.tokensIn).reduce(0, +), tokensOut: slice.map(\.tokensOut).reduce(0, +), turns: slice.map(\.turns).reduce(0, +)) }
        return AgentUsage(today: sum(list.suffix(1)), week: sum(list.suffix(7)), month: sum(list[...]), days: list)
    }

    /// About five months of daily usage for the heatmaps: quiet weekends, a busy stretch, a pause.
    static let history: UsageHistory = {
        let bases = [("ag_buzz", 2_400_000), ("ag_ada", 900_000), ("ag_nico", 1_300_000), ("ag_radix", 300_000)]
        let today = Heatmap.dayKey(now, timeZone: .current)
        var rows: [UsageHistory.Row] = []
        for (offset, (agent, base)) in bases.enumerated() {
            let span = offset == 0 ? 365 : 150 - offset * 35
            for index in 0..<span {
                let date = Calendar.current.date(byAdding: .day, value: index - span + 1, to: now)!
                let weekday = Calendar.current.component(.weekday, from: date)
                if (index * 7 + offset * 3) % 11 == 0 || (index > 40 && index < 48 && offset != 0) { continue }
                let wave = (sin(Double(index + offset * 5) / 6) + 1.25) * (index > span - 30 ? 1.6 : 1)
                let total = Int(Double(base) * wave * (weekday == 1 || weekday == 7 ? 0.25 : 1))
                rows.append(UsageHistory.Row(agentId: agent, day: Heatmap.dayKey(date, timeZone: .current), tokensIn: total * 4 / 5, tokensOut: total / 5, turns: max(1, total / 40_000)))
            }
        }
        return UsageHistory(today: today, usage: rows)
    }()

    static let thinking = Step(kind: .thinking, at: now.addingTimeInterval(-40), text: "The snapshot has the accounts already: I map each subscription to the agents that run on it before drawing the bars.")

    static let steps: [String: [Step]] = ["tr_buzz": [
        Step(kind: .note, at: now.addingTimeInterval(-180), text: "Obiettivo: app macOS compilata e verificata"),
        Step(kind: .thinking, at: now.addingTimeInterval(-150), text: "The panel already has the quotas: I expose them read-only with a device token instead of the cookie."),
        Step(kind: .tool, at: now.addingTimeInterval(-120), name: "shell", args: "{command: \"node --test test/app-access.test.js\"}", result: "ok 1 - pairs once\nok 2 - live reasoning\nok 3 - throttles guesses"),
        Step(kind: .text, at: now.addingTimeInterval(-60), text: "Server side is ready on its branch. Now the Swift app."),
        thinking,
    ]]

    static func items(_ texts: [String]) -> [Plan.Item] { texts.enumerated().map { Plan.Item(id: "item_\($0.offset)_\($0.element.prefix(6))", text: $0.element) } }

    static let planItems = items(["Server: /app/v1/plans and plans in the snapshot", "Tests on the touched parts", "macOS: Plans page in the window", "iOS: plans in progress and history", "Release and install on the MacBook"])

    static let plans: PlanBoard = {
        let buzz = Plan(id: "plan_buzz", agentId: "ag_buzz", agentName: "Buzz", color: "#f2a93b", channelId: "1572562024360054865", threadName: "App macOS: quote e reasoning dal vivo", link: "https://discord.com/channels/1/2",
                        name: "Plans in the API and the apps", status: .active, items: planItems, done: 2, updatedAt: now.addingTimeInterval(-240),
                        tasks: [Plan.Reasoned(id: planItems[0].id, text: planItems[0].text, count: 38), Plan.Reasoned(id: planItems[1].id, text: planItems[1].text, count: 12), Plan.Reasoned(id: planItems[2].id, text: planItems[2].text, count: 5)])
        let ada = Plan(id: "plan_ada", agentId: "ag_ada", agentName: "Ada", color: "#4f9cf7", channelId: "1570828502696075334", threadName: "Import Airbnb",
                       name: "Gate MTR-1468 on production", status: .blocked, items: items(["Read the release notes", "Run the gate on staging", "Phil checks while signed in"]), done: 2,
                       blockedReason: "Waiting for Phil to try it while signed in", updatedAt: now.addingTimeInterval(-3600 * 2))
        let history = [
            Plan(id: "plan_h1", agentId: "ag_nico", agentName: "Nico", color: "#e05aa5", channelId: "1571", threadName: "Fish voice per agent", name: "One Fish key per agent", status: .completed,
                 items: items(["Store the key per agent", "Read it in the voice call", "Test on Dopamina"]), done: 3, updatedAt: now.addingTimeInterval(-86400)),
            Plan(id: "plan_h2", agentId: "ag_buzz", agentName: "Buzz", color: "#f2a93b", channelId: "1572", threadName: "REF-121 geo sweep", name: "Gate the geo sweep", status: .completed,
                 items: items(["Migrate a clean database", "Run the touched tests", "Comment on the PR"]), done: 3, updatedAt: now.addingTimeInterval(-86400 * 1.4)),
            Plan(id: "plan_h3", agentId: "ag_radix", agentName: "Radix", color: "#3fbf8f", channelId: "1573", threadName: "Docker on the Mac Pro", name: "Restart Docker without a password", status: .closed,
                 items: items(["Find what stopped it", "Repair vmnetd", "Check the three sites"]), done: 1, updatedAt: now.addingTimeInterval(-86400 * 3)),
        ]
        return PlanBoard(open: [buzz, ada], history: history, next: "older")
    }()

    static let planSteps: [Step] = [
        Step(kind: .thinking, at: now.addingTimeInterval(-900), text: "The snapshot needs every open plan, not only the thread's: one query across threads, scoped like the board."),
        Step(kind: .tool, at: now.addingTimeInterval(-840), name: "shell", args: "{command: \"node --test test/app-access.test.js\"}", result: "ok 4 - the app reads plans across threads"),
        Step(kind: .text, at: now.addingTimeInterval(-800), text: "Server side done: /app/v1/plans, the snapshot and the live plan event."),
    ]

    static let snapshot: Snapshot = {
        let reset5h = now.addingTimeInterval(2 * 3600 + 600), resetWeek = now.addingTimeInterval(3 * 86400 + 4 * 3600)
        let claude = Account(id: "sub_claude", provider: "claude", label: "Claude Max", email: "seb@usecora.space", plan: "max",
            usage: QuotaUsage(windows: [QuotaWindow(id: "five_hour", kind: .session, usedPercent: 38, resetsAt: reset5h), QuotaWindow(id: "seven_day", kind: .weekly, usedPercent: 71, resetsAt: resetWeek),
                                        QuotaWindow(id: "weekly:fable", kind: .weekly, group: "Fable", usedPercent: 22, resetsAt: resetWeek)]), agentIds: ["ag_buzz", "ag_ada"])
        let codex = Account(id: "sub_codex", provider: "codex", label: "ChatGPT Pro", email: "seb@usecora.space", plan: "pro",
            usage: QuotaUsage(windows: [QuotaWindow(id: "codex:primary", kind: .session, usedPercent: 84, resetsAt: now.addingTimeInterval(41 * 60)), QuotaWindow(id: "codex:secondary", kind: .weekly, usedPercent: 46, resetsAt: resetWeek)]), agentIds: ["ag_nico"])
        let gemini = Account(id: "sub_gemini", provider: "gemini", label: "Gemini", email: "seb@usecora.space", plan: "pro",
            usage: QuotaUsage(windows: [QuotaWindow(id: "gemini:daily", kind: .custom, usedPercent: 12, resetsAt: now.addingTimeInterval(9 * 3600), minutes: 1440)]), agentIds: [])
        let kimi = Account(id: "sub_kimi", provider: "kimi", label: "Kimi", email: "agents@usecora.space", usage: QuotaUsage(state: "unavailable", windows: [], issue: "AUTH_REQUIRED"), agentIds: ["ag_radix"])
        let claudeBuzz = Account(id: "sub_claude_buzz", provider: "claude", label: "", email: "buzz@usecora.space", plan: "max",
            usage: QuotaUsage(windows: [QuotaWindow(id: "five_hour", kind: .session, usedPercent: 30, resetsAt: now.addingTimeInterval(6700)), QuotaWindow(id: "seven_day", kind: .weekly, usedPercent: 12, resetsAt: resetWeek)]), agentIds: ["ag_ada"])
        let grok = Account(id: "sub_grok", provider: "grok", label: "Grok", email: "seb@usecora.space",
            usage: QuotaUsage(windows: [QuotaWindow(id: "grok:weekly", kind: .weekly, usedPercent: 1, resetsAt: now.addingTimeInterval(6 * 86400))]), agentIds: [])
        let muse = Account(id: "sub_muse", provider: "muse", label: "Meta", email: "seb@usecora.space",
            usage: QuotaUsage(windows: [QuotaWindow(id: "muse:weekly", kind: .weekly, usedPercent: 93, resetsAt: now.addingTimeInterval(4 * 86400 + 9 * 3600))]), agentIds: [])
        let ollama = Account(id: "sub_ollama", provider: "ollama", label: "Ollama Cloud", email: "seb@usecora.space",
            usage: QuotaUsage(windows: [QuotaWindow(id: "ollama:monthly", kind: .custom, usedPercent: 21, resetsAt: now.addingTimeInterval(25 * 86400), minutes: 43200)]), agentIds: [])
        let deepseek = Account(id: "provider_deepseek", provider: "deepseek", label: "DeepSeek", server: true,
            usage: QuotaUsage(windows: [], balances: [Balance(kind: "total", currency: "USD", amount: "14.90"), Balance(kind: "granted", currency: "USD", amount: "0.00"), Balance(kind: "topped-up", currency: "USD", amount: "14.90")]), agentIds: [])
        let live = LiveTrace(traceId: "tr_buzz", channelId: "1572562024360054865", threadName: "App macOS: quote e reasoning dal vivo", link: "https://discord.com/channels/1/2",
                             startedAt: now.addingTimeInterval(-195), model: "claude/claude-opus-5-5", goal: "The macOS app builds and reads agents, quotas and live reasoning from the chosen space.", tokensIn: 184_200, tokensOut: 12_900, stepCount: 42, lastStep: thinking)
        let threads = [
            ThreadInfo(id: "1572562024360054865", name: "App macOS: quote e reasoning dal vivo", status: "active", lastAt: now, reasoning: thinking.text, tokensIn: 184_200, tokensOut: 12_900),
            ThreadInfo(id: "1570828502696075334", name: "Import Airbnb", listening: false, status: "ended", lastAt: now.addingTimeInterval(-3600 * 3), reasoning: "Droplet health is green; FF still waits for the residential credential."),
        ]
        let agents = [
            Agent(id: "ag_buzz", name: "Buzz", color: "#f2a93b", model: "claude/claude-opus-5-5", state: .working, accountIds: ["sub_claude"], usage: usage(52_000), live: [live], threads: threads),
            Agent(id: "ag_ada", name: "Ada", color: "#4f9cf7", model: "claude/claude-sonnet-5", state: .listening, accountIds: ["sub_claude"], usage: usage(31_000), threads: [threads[1]]),
            Agent(id: "ag_nico", name: "Nico", color: "#e05aa5", model: "codex/gpt-6", state: .idle, accountIds: ["sub_codex"], usage: usage(18_000)),
            Agent(id: "ag_radix", name: "Radix", color: "#3fbf8f", enabled: false, model: "hermes/kimi-k3", state: .off, accountIds: ["sub_kimi"], usage: usage(4_000)),
        ]
        return Snapshot(space: .init(name: "notseb", origin: "https://notseb.usecora.space"), user: .init(id: "u_seb", name: "Sebastiano", email: "seb@usecora.space", role: "owner"), accounts: [claude, claudeBuzz, codex, grok, muse, gemini, kimi, ollama, deepseek], agents: agents, plans: plans)
    }()

    static let requests: [ChoiceRequest] = [
        ChoiceRequest(id: "ch_0a1b2c3d4e5f", agentId: "ag_buzz", agentName: "Buzz", color: "#f2a93b", channelId: "1572562024360054865", threadName: "App macOS: quote e reasoning dal vivo",
                      link: "https://discord.com/channels/1/2", question: "The 0.2.15 build is ready and signed. Shall I install it on the MacBook now or wait until tonight?", choices: ["Install now", "Tonight", "Don't install"], askedAt: now.addingTimeInterval(-240)),
        ChoiceRequest(id: "ch_6f5e4d3c2b1a", agentId: "ag_ada", agentName: "Ada", color: "#4f9cf7", channelId: "1570828502696075334", threadName: "Import Airbnb",
                      question: "The gate passed on staging. Promote to production?", choices: ["Yes", "No"], askedAt: now.addingTimeInterval(-1500)),
        ChoiceRequest(id: "ch_99887766aabb", agentId: "ag_nico", agentName: "Nico", color: "#e05aa5", channelId: "1563845389705023658", threadName: "#cora",
                      question: "Which voice for the jingle?", choices: ["Warm", "Bright"], askedAt: now.addingTimeInterval(-4000)),
    ]

    /// The sample space with agents waiting for an answer.
    static let asking: Snapshot = { var copy = snapshot; copy.requests = requests; return copy }()

    @MainActor static func selection() -> LiveSelection {
        let selection = LiveSelection()
        selection.agentId = "ag_buzz"
        return selection
    }
}
