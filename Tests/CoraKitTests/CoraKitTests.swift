import Foundation
import Testing
@testable import CoraKit

@Suite struct SnapshotTests {
    func fixture() throws -> Snapshot {
        let url = try #require(Bundle.module.url(forResource: "snapshot", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }

    @Test func decodesAgentsAccountsAndUsage() throws {
        let snapshot = try fixture()
        #expect(snapshot.space.name == "notseb")
        #expect(snapshot.user.role == "owner")
        #expect(snapshot.accounts.count == 2, "a broken account is skipped, not fatal")
        #expect(snapshot.agents.map(\.name) == ["Buzz", "Ada"])
        let buzz = try #require(snapshot.agent("ag_a"))
        #expect(buzz.state == .working)
        #expect(buzz.usage.today.total == 1500)
        #expect(buzz.usage.month.turns == 9)
        #expect(buzz.live.first?.lastStep?.kind == .thinking)
        #expect(buzz.live.first?.lastStep?.text == "Checking the quotas")
        #expect(buzz.threads.first?.status == "active")
        #expect(snapshot.accounts(of: buzz).map(\.id) == ["sb_1"])
        let ada = try #require(snapshot.agent("ag_b"))
        #expect(ada.state == .idle, "an unknown state reads as idle")
        #expect(ada.usage.today == .zero)
    }

    @Test func windowsAndTightestQuota() throws {
        let snapshot = try fixture()
        let claude = snapshot.accounts[0]
        #expect(claude.usage?.windows.count == 4)
        #expect(claude.usage?.windows[3].kind == .custom, "unknown window kinds stay readable")
        #expect(claude.tightestWindow?.id == "seven_day", "model-scoped limits do not count for the account")
        #expect(claude.tightestWindow?.level == .warning)
        #expect(snapshot.tightest?.window.remainingPercent == 18.5)
        #expect(snapshot.accounts[1].usage?.balances.first?.amount == "3.20")
        #expect(snapshot.accounts[1].usage?.issue == "AUTH_REQUIRED")
        #expect(Providers.name("brand-new") == "Brand-new")
    }
}

@Suite struct PlanTests {
    func fixture() throws -> Snapshot {
        let url = try #require(Bundle.module.url(forResource: "snapshot", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }

    @Test func decodesOpenPlansAndHistory() throws {
        let plans = try #require(try fixture().plans)
        #expect(plans.open.map(\.id) == ["pl-1", "pl-2"], "a plan with an unknown status is skipped, not fatal")
        let running = plans.open[0]
        #expect(running.isOpen && running.status == .active)
        #expect(running.current?.text == "macOS")
        #expect(running.progress == 1.0 / 3.0)
        #expect(running.reasoned(running.items[0])?.count == 12)
        #expect(running.reasoned(running.items[1]) == nil)
        #expect(running.link == "https://discord.com/channels/1/157")
        #expect([running.state(of: 0), running.state(of: 1), running.state(of: 2)] == [.done, .current, .pending])
        let blocked = plans.open[1]
        #expect(blocked.status == .blocked && blocked.blockedReason == "Phil")
        #expect(blocked.state(of: 0) == .blocked)
        #expect(plans.history.map(\.status) == [.completed, .closed])
        #expect(plans.history[1].state(of: 1) == .dropped, "what a closed plan left undone")
        #expect(plans.history[0].current == nil)
        #expect(plans.next == "2026-11-18T19:00:00.000Z|pl-4")
        #expect(try fixture().openPlans(of: "ag_a").map(\.id) == ["pl-1"])
    }

    @Test func closingRequiresAnOpenPlanWithPermissionAndRevision() throws {
        func allows(_ status: String, fields: String) throws -> Bool {
            let json = #"{"id":"p","status":"\#(status)"\#(fields)}"#
            return try JSONDecoder().decode(Plan.self, from: Data(json.utf8)).allowsOwnerClose
        }
        let allowed = #","canClose":true,"revision":2"#
        #expect(try allows("active", fields: allowed))
        #expect(try allows("blocked", fields: allowed))
        #expect(try !allows("completed", fields: allowed))
        #expect(try !allows("closed", fields: allowed))
        #expect(try !allows("active", fields: ""))
        #expect(try !allows("active", fields: #","canClose":true"#))
        #expect(try !allows("active", fields: #","canClose":false,"revision":2"#))
    }

    @Test func olderServersHaveNoPlans() throws {
        let json = #"{"version":1,"space":{"name":"s","origin":"https://s"},"user":{"id":"u","name":"U","email":"","role":"owner"},"accounts":[],"agents":[]}"#
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        #expect(snapshot.plans == nil)
        #expect(snapshot.openPlans(of: "ag_a").isEmpty)
    }

    @Test func decodesQuestionsWithChoices() throws {
        let json = ##"{"version":1,"space":{"name":"s","origin":"https://s"},"user":{"id":"u","name":"U","email":"","role":"owner"},"accounts":[],"agents":[],"requests":[{"id":"ch_0a1b2c3d4e5f","agentId":"ag_a","agentName":"Olga","color":"#4f9cf7","channelId":"123","threadName":"Launch","link":"https://discord.com/channels/1/123","question":"Publish now?","choices":["Publish","Later"],"askedAt":"2026-11-20T07:30:00.000Z"},{"agentId":"no-id"}]}"##
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        #expect(snapshot.requests.map(\.id) == ["ch_0a1b2c3d4e5f"], "a question without an id is skipped, not fatal")
        let request = try #require(snapshot.requests.first)
        #expect(request.choices == ["Publish", "Later"] && request.question == "Publish now?" && request.agentName == "Olga" && request.askedAt != nil)
        let older = try JSONDecoder().decode(Snapshot.self, from: Data(#"{"version":1,"space":{"name":"s","origin":"https://s"},"user":{"id":"u","name":"U","email":"","role":"owner"},"accounts":[],"agents":[]}"#.utf8))
        #expect(older.requests.isEmpty, "servers without questions list none")
        let answer = try JSONDecoder().decode(ChoiceAnswer.self, from: Data(#"{"id":"ch_0a1b2c3d4e5f","answer":"Later"}"#.utf8))
        #expect(answer.answer == "Later")
        let event = try #require(ServerEvent.decode(#"{"type":"choice","agentId":"ag_a","channelId":"123","id":"ch_0a1b2c3d4e5f","status":"answered"}"#))
        #expect(event.type == "choice" && event.choiceId == "ch_0a1b2c3d4e5f" && event.status == "answered")
    }

    @Test func decodesPagesReasoningAndPlanEvents() throws {
        let page = try JSONDecoder().decode(PlanPage.self, from: Data(#"{"status":"history","plans":[{"id":"p","agentId":"a","name":"N","status":"completed","items":[{"id":"x","text":"X"}],"done":1}],"next":null}"#.utf8))
        #expect(page.plans.count == 1 && page.next == nil)
        let reasoning = try JSONDecoder().decode(PlanTaskReasoning.self, from: Data(#"{"plan":{"id":"p"},"task":{"id":"x","text":"X"},"events":[{"seq":9,"traceId":"tr_1","step":{"type":"thinking","text":"Why","at":1795000000000},"startedAt":1795000000000}],"next":null}"#.utf8))
        #expect(reasoning.events.first?.step.kind == .thinking)
        #expect(reasoning.events.first?.step.text == "Why")
        let event = try #require(ServerEvent.decode(#"{"type":"plan","agentId":"ag_a","channelId":"157","planId":"pl-1","status":"completed","done":3,"total":3}"#))
        #expect(event.type == "plan" && event.planId == "pl-1" && event.status == "completed")
    }
}

@Suite struct EventTests {
    @Test func parsesServerSentEvents() {
        var parser = EventParser()
        #expect(parser.feed("retry: 3000") == nil)
        #expect(parser.feed("") == nil)
        #expect(parser.feed(": ping") == nil)
        #expect(parser.feed(#"data: {"type":"trace","event":"step","traceId":"tr_1","agentId":"ag_a","step":{"at":1795000000000,"type":"tool","name":"shell","args":{"command":"ls","n":2},"result":"ok"}}"#) == nil)
        let payload = parser.feed("")
        let event = ServerEvent.decode(payload ?? "")
        #expect(event?.type == "trace")
        #expect(event?.step?.kind == .tool)
        #expect(event?.step?.args == #"{command: "ls", n: 2}"#)
        #expect(event?.step?.at == Date(timeIntervalSince1970: 1_795_000_000))
        #expect(parser.feed("data: first") == nil)
        #expect(parser.feed("data: second") == nil)
        #expect(parser.feed("") == "first\nsecond")
    }

    @Test func decodesTraceEnd() {
        let event = ServerEvent.decode(#"{"type":"trace","event":"end","trace":{"id":"tr_1","agentId":"ag_a","status":"ok","tokensIn":5,"tokensOut":1,"output":"done"}}"#)
        #expect(event?.trace?.status == "ok")
        #expect(event?.step == nil)
    }
}

@Suite struct PairingTests {
    let code = "cora_pair_" + String(repeating: "a", count: 43)

    @Test func acceptsPanelLinks() throws {
        let link = try ConnectLink.parse(URL(string: "cora://connect?server=https%3A%2F%2Fnotseb.usecora.space&code=\(code)&state=abcdefghijklmnop")!)
        #expect(link.server.absoluteString == "https://notseb.usecora.space")
        #expect(link.code == code)
        #expect(link.state == "abcdefghijklmnop")
        #expect(try ConnectLink.parse(URL(string: "cora://connect?server=http://127.0.0.1:4100&code=\(code)")!).state == nil)
    }

    @Test func refusesOtherLinks() {
        #expect(throws: ConnectLink.Problem.insecureServer) { try ConnectLink.parse(URL(string: "cora://connect?server=http://evil.example&code=\(code)")!) }
        #expect(throws: ConnectLink.Problem.missingCode) { try ConnectLink.parse(URL(string: "cora://connect?server=https://notseb.usecora.space&code=short")!) }
        #expect(throws: ConnectLink.Problem.notACoraLink) { try ConnectLink.parse(URL(string: "https://notseb.usecora.space/connect?code=\(code)")!) }
        #expect(throws: ConnectLink.Problem.notACoraLink) { try ConnectLink.parse(URL(string: "cora://other?server=https://a.b&code=\(code)")!) }
    }

    @Test func spaceAddresses() {
        #expect(Space.origin("notseb.usecora.space")?.absoluteString == "https://notseb.usecora.space")
        #expect(Space.origin(" https://NotSeb.usecora.space/#/agenti ")?.absoluteString == "https://notseb.usecora.space")
        #expect(Space.origin("http://127.0.0.1:4100/x")?.absoluteString == "http://127.0.0.1:4100")
        #expect(Space.origin("ftp://x.y") == nil)
        #expect(Space.origin("https://user:pw@x.y") == nil)
        let state = Space.newState()
        #expect(state.count == 43)
        #expect(Space.authorizeURL(origin: URL(string: "https://notseb.usecora.space")!, state: state).absoluteString == "https://notseb.usecora.space/#/app?state=\(state)")
    }
}

@Suite struct FormatTests {
    @Test func tokensAndTimes() {
        #expect(Format.tokens(950) == "950")
        #expect(Format.tokens(45_200) == "45.2k")
        #expect(Format.tokens(1_000) == "1k")
        #expect(Format.tokens(250_000) == "250k")
        #expect(Format.tokens(1_250_000) == "1.25M")
        #expect(Format.tokens(3_100_000_000) == "3.1B")
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Format.countdown(to: now.addingTimeInterval(12 * 60), from: now, italian: false) == "12m")
        #expect(Format.countdown(to: now.addingTimeInterval(130 * 60), from: now, italian: false) == "2h 10m")
        #expect(Format.countdown(to: now.addingTimeInterval(76 * 3600), from: now, italian: true) == "3g 4h")
        #expect(Format.ago(now.addingTimeInterval(-10), from: now, italian: false) == "now")
        #expect(Format.ago(now.addingTimeInterval(-180), from: now, italian: false) == "3 min ago")
        #expect(Format.elapsed(since: now.addingTimeInterval(-65), now: now) == "1:05")
        #expect(Format.model("claude/claude-opus-5-5") == "claude-opus-5-5")
    }
}

@Suite(.serialized) struct PinTests {
    func fixture() throws -> Snapshot {
        let url = try #require(Bundle.module.url(forResource: "snapshot", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }

    @Test func onlyPinnedSubscriptionsReachTheMenuBar() throws {
        let snapshot = try fixture()
        #expect(snapshot.pinned([]).isEmpty, "nothing pinned shows no quota at all")
        let ids = snapshot.accounts.map(\.id)
        let one = snapshot.pinned([ids[0]])
        #expect(one.count == 1)
        #expect(one[0].accountId == ids[0])
        #expect(one[0].text == "\(Providers.name(snapshot.accounts[0].provider)) 5h 58% · 7d 19%", "both account-wide limits, each named by its length")
        #expect(one[0].value == "19%" && one[0].provider == snapshot.accounts[0].provider, "the menu bar draws the provider's icon, then what is left")
        #expect(snapshot.pinned(["gone", ids[1]]).map(\.accountId) == [ids[1]], "a subscription removed from the space drops out")
        #expect(snapshot.pinned([ids[1], ids[0]]).map(\.accountId) == ids, "the order of the space, not of the clicks")
        let unread = try #require(snapshot.pinned([ids[1]]).first)
        if snapshot.accounts[1].tightestWindow == nil { #expect(unread.text.hasSuffix("–")) }
    }

    @Test func twoLimitsAreShownApartAndNamed() throws {
        let snapshot = try fixture()
        let claude = snapshot.accounts[0]
        #expect(claude.mainWindows.map(\.id) == ["five_hour", "seven_day"], "the 5-hour session above the week; model-scoped and unknown windows stay in the details")
        #expect(claude.allWindows.map(\.id) == ["five_hour", "seven_day", "x", "weekly:fable"], "the details list every window, account-wide first")
        #expect(claude.mainWindows.map { $0.tag(italian: false) } == ["5h", "7d"])
        #expect(claude.mainWindows.map { $0.tag(italian: true) } == ["5h", "7g"])
        let pin = try #require(snapshot.pinned([claude.id]).first)
        #expect(pin.value == "19%", "the single figure is still the tightest window")
        #expect(pin.windows.map(\.id) == ["five_hour", "seven_day"], "the menu bar stacks both limits")
        let daily = QuotaWindow(id: "d", kind: .custom, usedPercent: 1, resetsAt: nil, minutes: 1440)
        let month = QuotaWindow(id: "m", kind: .custom, usedPercent: 1, resetsAt: nil, minutes: 43_200)
        #expect(daily.tag(italian: false) == "24h" && month.tag(italian: false) == "30d")
        let single = Account(id: "g", provider: "grok", label: "Grok", usage: QuotaUsage(windows: [QuotaWindow(id: "w", kind: .weekly, usedPercent: 1, resetsAt: nil)]), agentIds: [])
        #expect(single.mainWindows.count == 1, "one limit, one line")
    }

    @Test func payAsYouGoAccountsShowTheirBalance() throws {
        // The shape notseb sends for DeepSeek: a valid reading with no percentage window, only balances.
        let json = #"{"id":"provider_deepseek","provider":"deepseek","label":"DeepSeek","status":"ready","server":true,"usage":{"windows":[],"balances":[{"kind":"total","currency":"USD","amount":"14.90"},{"kind":"granted","currency":"USD","amount":"0.00"},{"kind":"topped-up","currency":"USD","amount":"14.90"}],"fetchedAt":"2026-11-18T14:44:38.101Z","state":"ready","issue":null},"agentIds":[]}"#
        let deepseek = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        #expect(deepseek.tightestWindow == nil)
        #expect(deepseek.balance?.kind == "total" && deepseek.balance?.amount == "14.90", "the total, not the bonus or the top-ups")
        let snapshot = Snapshot(space: .init(name: "s", origin: "https://s.usecora.space"), user: .init(id: "u", name: "U", email: "u@x", role: "owner"),
                                accounts: [deepseek, Account(id: "e", provider: "deepseek", label: "Empty", usage: QuotaUsage(windows: [], balances: [Balance(kind: "total", currency: "USD", amount: "0.00")]), agentIds: [])], agents: [])
        let pin = try #require(snapshot.pinned([deepseek.id]).first)
        #expect(pin.value != "–" && pin.value.contains("14"), "the menu bar shows the balance instead of no reading")
        #expect(pin.level == nil)
        #expect(snapshot.pinned(["e"]).first?.level == .critical, "an empty balance is red")
        #expect(Format.money("14.90", currency: "USD", locale: Locale(identifier: "en_US")) == "$14.90")
        #expect(Format.money("14.90", currency: "USD", locale: Locale(identifier: "it_IT")).hasPrefix("14,90"))
        #expect(Format.money("0.5", currency: "CNY", locale: Locale(identifier: "en_US")).contains("0.50"))
        let signedOut = Account(id: "k", provider: "deepseek", label: "", usage: QuotaUsage(state: "unavailable", windows: [], balances: [Balance(kind: "total", currency: "USD", amount: "3.20")], issue: "AUTH_REQUIRED"), agentIds: [])
        #expect(signedOut.balance == nil, "an account that must sign in again does not show its last balance")
    }

    @Test func searchFindsAgentsByNameModelAndWork() {
        let agents = [Agent(id: "a", name: "Primo", color: "#000", model: "grok/grok-4.7", state: .idle, accountIds: [], usage: .init(today: .zero, week: .zero, month: .zero, days: [])),
                      Agent(id: "b", name: "Véra", color: "#000", model: "claude/claude-opus-5-5", state: .idle, accountIds: [], usage: .init(today: .zero, week: .zero, month: .zero, days: []),
                            threads: [ThreadInfo(id: "t", name: "Ragusa Buzz social", status: "active", lastAt: nil, reasoning: "", tokensIn: 0, tokensOut: 0)])]
        #expect(Agent.matching(agents, "").map(\.id) == ["a", "b"])
        #expect(Agent.matching(agents, "prim").map(\.id) == ["a"])
        #expect(Agent.matching(agents, "vera").map(\.id) == ["b"], "accents do not matter")
        #expect(Agent.matching(agents, "opus ragusa").map(\.id) == ["b"], "every word, from the model and the threads")
        #expect(Agent.matching(agents, "nobody").isEmpty)
    }

    @Test func searchFindsPlansByNameAgentThreadAndChecklist() {
        let plans = [Plan(id: "p", agentId: "a", agentName: "Primo", channelId: "c", threadName: "App iOS/macOS", name: "Chiudi piano", status: .active, items: [.init(id: "1", text: "Provare il percorso server")], done: 0, updatedAt: nil),
                     Plan(id: "q", agentId: "b", agentName: "Véra", channelId: "d", threadName: "Ragusa Buzz", name: "Reel di novembre", status: .blocked, items: [.init(id: "2", text: "Render dei reel")], done: 0, blockedReason: "Manca la musica", updatedAt: nil)]
        #expect(Plan.matching(plans, " ").map(\.id) == ["p", "q"])
        #expect(Plan.matching(plans, "chiudi").map(\.id) == ["p"])
        #expect(Plan.matching(plans, "vera").map(\.id) == ["q"], "accents do not matter")
        #expect(Plan.matching(plans, "macos server").map(\.id) == ["p"], "every word, from the thread and the checklist")
        #expect(Plan.matching(plans, "musica").map(\.id) == ["q"], "the blocker counts")
        #expect(Plan.matching(plans, "nobody").isEmpty)
    }

    @Test func twoSubscriptionsOfOneProviderKeepTheirLabels() {
        let usage = QuotaUsage(windows: [QuotaWindow(id: "w", kind: .weekly, usedPercent: 40, resetsAt: nil)])
        let snapshot = Snapshot(space: .init(name: "s", origin: "https://s.usecora.space"), user: .init(id: "u", name: "U", email: "u@x", role: "owner"),
                                accounts: [Account(id: "a", provider: "claude", label: "Max Seb", usage: usage, agentIds: []),
                                           Account(id: "b", provider: "claude", label: "", email: "team@usecora.space", usage: usage, agentIds: []),
                                           Account(id: "c", provider: "codex", label: "ChatGPT Pro", usage: nil, agentIds: [])], agents: [])
        #expect(snapshot.pinned(["a", "b", "c"]).map(\.text) == ["Claude · Max Seb 60%", "Claude · team 60%", "Codex –"])
        #expect(snapshot.pinned(["c"]).map(\.value) == ["–"], "no reading yet")
        let same = Snapshot(space: snapshot.space, user: snapshot.user,
                            accounts: [Account(id: "x", provider: "claude", label: "Claude", email: "seb@usecora.space", usage: usage, agentIds: []),
                                       Account(id: "y", provider: "claude", label: "Claude", email: "radix@usecora.space", usage: usage, agentIds: [])], agents: [])
        #expect(same.pinned(["x", "y"]).map(\.title) == ["Claude · seb", "Claude · radix"], "a label that only repeats the provider gives way to the address")
        #expect(snapshot.accounts.map { snapshot.title(of: $0) } == ["Claude · Max Seb", "Claude · team", "Codex"], "the Tokens list names each subscription on one line")
        #expect(snapshot.pinned(["a"]).map(\.title) == ["Claude"], "the menu bar adds the label only when two pinned ones share a provider")
    }

    @Test func spacesAreAListAndTheOldSingleSpaceMovesIn() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cora-spaces-\(UUID().uuidString)")
        setenv("CORA_APP_HOME", home.path, 1)
        defer { unsetenv("CORA_APP_HOME"); try? FileManager.default.removeItem(at: home) }
        #expect(Storage.loadConnections().isEmpty)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let notseb = Connection(server: URL(string: "https://notseb.usecora.space")!, spaceName: "notseb", userName: "Seb", email: "s@x.it", deviceId: "dev_1")
        try encoder.encode(notseb).write(to: home.appendingPathComponent("connection.json"))
        #expect(Storage.loadConnections().map(\.server) == [notseb.server], "the space of an older version is kept")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("connection.json").path))
        let dopamina = Connection(server: URL(string: "https://dopamina.usecora.space")!, spaceName: "Dopamina", userName: "Seb", email: "s@x.it", deviceId: "dev_2")
        try Storage.write([notseb, dopamina])
        var renamed = notseb; renamed.spaceName = "notseb world"
        Storage.update(renamed)
        #expect(Storage.loadConnections().map(\.spaceName) == ["notseb world", "Dopamina"])
        #expect(Storage.connection(server: dopamina.server)?.deviceId == "dev_2")
        Storage.forget(notseb)
        #expect(Storage.loadConnections().map(\.server) == [dopamina.server], "forgetting one space keeps the others")
        #expect(Storage.loadConnection()?.server == dopamina.server)
    }

    @Test func dismissedQuestionsStayHiddenPerSpaceForAWeek() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cora-dismissed-\(UUID().uuidString)")
        setenv("CORA_APP_HOME", home.path, 1)
        defer { unsetenv("CORA_APP_HOME"); try? FileManager.default.removeItem(at: home) }
        let notseb = try #require(URL(string: "https://notseb.usecora.space")), other = try #require(URL(string: "https://dopamina.usecora.space"))
        let asked = ChoiceRequest(id: "ch_06a79a74c48c", agentId: "ag_vera", agentName: "Vera", channelId: "1563814774452518986", question: "Come procedo?", choices: ["Aspetto", "Ricontrolla"])
        let kept = ChoiceRequest(id: "ch_99887766aabb", agentId: "ag_nico", agentName: "Nico", channelId: "1563845389705023658", question: "Which voice?", choices: ["Warm", "Bright"])
        var snapshot = try fixture()
        snapshot.requests = [asked, kept]
        #expect(snapshot.hidingDismissed(server: notseb).requests.map(\.id) == [asked.id, kept.id])
        let then = Date().addingTimeInterval(-3600)
        DismissedQuestions.add(asked.id, server: notseb, now: then)
        #expect(DismissedQuestions.load(server: notseb, now: then.addingTimeInterval(3600)) == [asked.id])
        #expect(DismissedQuestions.load(server: other, now: then).isEmpty, "another space keeps its questions")
        #expect(DismissedQuestions.load(server: notseb, now: then.addingTimeInterval(8 * 86_400)).isEmpty, "a week later the device forgets it")
        #expect(snapshot.hidingDismissed(server: notseb).requests.map(\.id) == [kept.id], "the snapshot no longer shows it on this device")
        #expect(snapshot.hidingDismissed(server: other).requests.count == 2)
    }

    @Test func pinsPersistPerSpace() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cora-pins-\(UUID().uuidString)")
        setenv("CORA_APP_HOME", home.path, 1)
        defer { unsetenv("CORA_APP_HOME"); try? FileManager.default.removeItem(at: home) }
        let notseb = URL(string: "https://notseb.usecora.space")!, other = URL(string: "https://dopamina.usecora.space")!
        #expect(Pins.load(server: notseb).isEmpty)
        try Pins.save(["sub_claude", "sub_codex"], server: notseb)
        try Pins.save(["sub_x"], server: other)
        #expect(Pins.load(server: notseb) == ["sub_claude", "sub_codex"])
        #expect(Pins.load(server: other) == ["sub_x"])
        try Pins.save([], server: notseb)
        #expect(Pins.load(server: notseb).isEmpty)
        #expect(Pins.load(server: other) == ["sub_x"])
    }

    @Test func heatmapFollowsThePanel() throws {
        let json = #"{"days":365,"today":"2026-11-18","usage":[{"agentId":"a","day":"2026-11-04","tokensIn":80,"tokensOut":20,"turns":2},{"agentId":"b","day":"2026-11-18","tokensIn":300,"tokensOut":50,"turns":3},{"agentId":"a","day":"2026-11-18","tokensIn":50,"tokensOut":0,"turns":1},{"agentId":"a","day":"2026-11-25","tokensIn":9,"tokensOut":0,"turns":1}]}"#
        let history = try JSONDecoder().decode(UsageHistory.self, from: Data(json.utf8))
        #expect(history.today == "2026-11-18")
        #expect(history.total() == 509 && history.total(agentId: "a") == 159)
        #expect(history.byDay()["2026-11-18"] == Heatmap.Spent(tokens: 400, turns: 4), "everyone together adds the agents up")
        let map = try #require(Heatmap(byDay: history.byDay(), today: history.today))
        #expect(map.firstDay == "2026-11-04" && map.lastDay == "2026-11-18", "from the first use to today, nothing after")
        #expect(map.rows == 7 && map.weeks.count == 3 && map.weeks.map(\.count) == [7, 7, 3], "weeks start on Monday: the 4th is a Wednesday")
        #expect(map.weeks[0].prefix(2).allSatisfy { $0.day == nil }, "two blank squares before the first Wednesday")
        #expect(map.weeks[0][2].day == "2026-11-04" && map.weeks[0][2].level == 1)
        #expect(map.weeks[2][2].day == "2026-11-18" && map.weeks[2][2].level == 4 && map.weeks[2][2].turns == 4)
        #expect(map.weeks[1].allSatisfy { $0.level == 0 }, "an empty day is level 0")
        #expect(map.months == [0: 10], "November labelled once")
        #expect(Heatmap.level(1, peak: 1_000_000) == 1 && Heatmap.level(500, peak: 1000) == 2 && Heatmap.level(999, peak: 1000) == 4)
        let single = try #require(Heatmap(byDay: ["2026-11-18": .init(tokens: 5, turns: 1)], today: "2026-11-18"))
        #expect(single.rows == 3 && single.weeks.count == 1, "a short history stays compact")
        #expect(Heatmap(byDay: [:], today: "2026-11-18") == nil)
        #expect(Heatmap(byDay: ["2026-11-19": .init(tokens: 5, turns: 1)], today: "2026-11-18") == nil)
    }

    @Test func heatmapFallsBackOnTheSnapshotMonth() {
        let usage = AgentUsage(today: .zero, week: .zero, month: .zero, days: [try! JSONDecoder().decode(DayTokens.self, from: Data(#"{"day":"2026-11-17","tokensIn":10,"tokensOut":5,"turns":1}"#.utf8))])
        let agent = Agent(id: "a", name: "A", color: "#000", model: "", state: .idle, accountIds: [], usage: usage)
        let snapshot = Snapshot(generatedAt: ISO8601DateFormatter().date(from: "2026-11-18T23:30:00Z"), timezone: "Europe/Rome",
                                space: .init(name: "s", origin: "https://s.usecora.space"), user: .init(id: "u", name: "U", email: "u@x", role: "owner"), accounts: [], agents: [agent])
        let history = UsageHistory(snapshot: snapshot)
        #expect(history.today == "2026-11-19", "today in the space's time zone")
        #expect(history.usage == [UsageHistory.Row(agentId: "a", day: "2026-11-17", tokensIn: 10, tokensOut: 5, turns: 1)])
    }
}

@Suite struct NoticeTests {
    @Test func readsTheTargetTheSpaceNames() throws {
        let plan = try #require(Notice(payload: ["planId": "plan_1", "channelId": "123", "kind": "plan-blocked", "url": "/#/thread/t/123", "space": "https://notseb.usecora.space"]))
        #expect(plan.route == .plan("plan_1"))
        #expect(plan.space?.host == "notseb.usecora.space")
        #expect(Notice(payload: ["channelId": "123", "kind": "thread"])?.route == .thread("123"))
        #expect(Notice(payload: ["agentId": "ag_a", "kind": "agent"])?.route == .agent("ag_a"))
        #expect(Notice(payload: ["kind": "quota", "url": "/"])?.route == .subscriptions)
        #expect(Notice(payload: ["kind": "panel", "url": "/#/artefatti/segreti"])?.route == .panel("/#/artefatti/segreti"))
        #expect(Notice(payload: ["aps": ["alert": ["title": "x"]]]) == nil)
    }

    @Test func readsOlderSpacesThatSendOnlyThePanelLink() {
        #expect(Notice(payload: ["url": "/#/thread/t/1572562024360054865"])?.route == .thread("1572562024360054865"))
        #expect(Notice(payload: ["url": "/#/thread/1572562024360054865"])?.route == .thread("1572562024360054865"))
        #expect(Notice(payload: ["url": "/#/agent/ag_ff893fe5cfb6/chat"])?.route == .agent("ag_ff893fe5cfb6"))
        #expect(Notice(payload: ["url": "/#/salotto"])?.route == .panel("/#/salotto"))
        #expect(Notice(payload: ["channelId": "web-ag_a"])?.route == .agent("ag_a"), "an agent's private panel room opens the agent")
        #expect(Notice(payload: ["url": "/#/thread/t/web"])?.route == .panel("/#/thread/t/web"))
    }

    @Test func opensPanelPagesOnTheSpaceAndMatchesItsSpace() throws {
        let origin = try #require(URL(string: "https://notseb.usecora.space"))
        #expect(Notice.panelURL("/#/artefatti/segreti", origin: origin)?.absoluteString == "https://notseb.usecora.space/#/artefatti/segreti")
        #expect(Notice.panelURL("https://notseb.usecora.space/#/brain", origin: origin)?.absoluteString == "https://notseb.usecora.space/#/brain")
        let notice = try #require(Notice(payload: ["channelId": "1", "space": "https://notseb.usecora.space"]))
        #expect(notice.belongs(to: origin))
        #expect(!notice.belongs(to: try #require(URL(string: "https://dopamina.usecora.space"))))
        #expect(try #require(Notice(payload: ["channelId": "1"])).belongs(to: origin), "a notice without its space belongs to the one on screen")
    }
}

#if os(macOS)
@Suite struct LocalSpaceTests {
    @Test func envRoundTripsQuotesAndKeepsKeysOutOfArguments() throws {
        let values = ["CORA_ADMIN_PASSWORD": "a'b c", "DEEPSEEK_API_KEY": "sk-123"]
        let text = LocalSpace.envText(values)
        #expect(text == "CORA_ADMIN_PASSWORD='a'\\''b c'\nDEEPSEEK_API_KEY='sk-123'\n")
        #expect(LocalSpace.parseEnv(text) == values)
        let space = LocalSpace(root: URL(fileURLWithPath: "/tmp/cora-local"))
        let data = try space.launchAgent(node: URL(fileURLWithPath: "/Applications/Cora.app/Contents/MacOS/cora-node"), main: URL(fileURLWithPath: "/Applications/Cora.app/Contents/Resources/cora-server/src/main.js"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "space.usecora.local")
        let arguments = try #require(plist["ProgramArguments"] as? [String])
        #expect(arguments.contains("/tmp/cora-local/env"))
        #expect(!String(decoding: data, as: UTF8.self).contains("sk-123"), "the key stays in the env file")
        let env = try #require(plist["EnvironmentVariables"] as? [String: String])
        #expect(env["PORT"] == "4370")
        #expect(env["CORA_HOME"] == "/tmp/cora-local/home")
    }

    @Test func machineStaysInItsOwnFoldersAndTheServerDrivesIt() throws {
        let space = LocalSpace(root: URL(fileURLWithPath: "/tmp/cora-local"), runtime: URL(fileURLWithPath: "/tmp/rt"))
        let tools = URL(fileURLWithPath: "/Applications/Cora.app/Contents/Resources/cora-vm/bin")
        let vm = space.vmEnvironment(tools: tools)
        #expect(vm["COLIMA_HOME"] == "/tmp/rt/colima")
        #expect(vm["LIMA_HOME"] == "/tmp/rt/lima")
        #expect(vm["DOCKER_CONFIG"] == "/tmp/rt/docker", "the user's ~/.docker is never touched")
        #expect(vm["PATH"]?.hasPrefix(tools.path + ":") == true, "colima finds the app's own limactl and docker")
        let arguments = LocalSpace.vmStartArguments(cores: 10, memory: 32 * 1_073_741_824)
        #expect(arguments == ["start", "cora", "--vm-type", "vz", "--runtime", "docker", "--cpu", "4", "--memory", "8", "--disk", "60", "--activate=false"])
        let small = LocalSpace.vmSize(cores: 4, memory: 8 * 1_073_741_824)
        #expect(small.cpus == 2 && small.memoryGB == 4 && small.diskGB == 60, "a small Mac still gives the VM 2 cores and 4 GB")
        let agent = try #require(try PropertyListSerialization.propertyList(from: space.vmLaunchAgent(colima: tools.appendingPathComponent("colima")), format: nil) as? [String: Any])
        #expect(agent["Label"] as? String == "space.usecora.vm")
        #expect(agent["KeepAlive"] == nil, "colima start boots the VM and exits; Lima keeps it running")
        #expect(agent["ProgramArguments"] as? [String] == [tools.appendingPathComponent("colima").path, "start", "cora", "--activate=false"])
        let server = space.serverEnvironment(tools: tools)
        #expect(server["CORA_DOCKER"] == tools.appendingPathComponent("docker").path)
        #expect(server["CORA_BOX_IMAGE"] == "cora-box:latest")
        #expect(server["DOCKER_CONFIG"] == "/tmp/rt/docker")
        #expect(space.serverEnvironment()["CORA_DOCKER"] == nil)
        let path = space.serverEnvironment(tools: tools, userPath: ["/opt/homebrew/bin", "/usr/bin", "relative", "/Users/me/.local/bin"])["PATH"] ?? ""
        let dirs = path.split(separator: ":").map(String.init)
        #expect(dirs.firstIndex(of: tools.path)! < dirs.firstIndex(of: "/opt/homebrew/bin")!, "the app's own tools come before the person's")
        #expect(dirs.contains("/Users/me/.local/bin") && !dirs.contains("relative"), "the login shell's folders join, only absolute ones")
        #expect(dirs.filter { $0 == "/usr/bin" }.count == 1, "no folder twice")
    }

    @Test func secretsAreFreshAndHoldNoModelKey() {
        let first = LocalSpace.secrets()
        let second = LocalSpace.secrets()
        #expect(Set(first.keys) == ["CORA_ADMIN_PASSWORD", "CORA_SESSION_KEY"])
        #expect(first["CORA_ADMIN_PASSWORD"] != second["CORA_ADMIN_PASSWORD"])
        #expect(first["CORA_SESSION_KEY"]?.count == 64)
    }
}
#endif
