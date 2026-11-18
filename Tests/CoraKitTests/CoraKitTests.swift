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
