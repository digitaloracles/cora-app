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
        #expect(one[0].text == "\(Providers.name(snapshot.accounts[0].provider)) 19%", "the tightest account-wide window of that subscription")
        #expect(one[0].value == "19%" && one[0].provider == snapshot.accounts[0].provider, "the menu bar draws the provider's icon, then what is left")
        #expect(snapshot.pinned(["gone", ids[1]]).map(\.accountId) == [ids[1]], "a subscription removed from the space drops out")
        #expect(snapshot.pinned([ids[1], ids[0]]).map(\.accountId) == ids, "the order of the space, not of the clicks")
        let unread = try #require(snapshot.pinned([ids[1]]).first)
        if snapshot.accounts[1].tightestWindow == nil { #expect(unread.text.hasSuffix("–")) }
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
}
