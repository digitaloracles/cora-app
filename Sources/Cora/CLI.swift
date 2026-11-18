import AppKit
import CoraKit
import SwiftUI

/// The app from the command line: connect, read, watch the live stream, render its views. Used by CI and for checks.
enum CLI {
    enum Command {
        case connect(String), print(String?), spaces, watch(TimeInterval), disconnect(String?), renderPreview(String), renderLive(String), version
    }

    static func command(_ arguments: [String]) -> Command? {
        guard let first = arguments.first else { return nil }
        let value = arguments.dropFirst().first
        switch first {
        case "--connect": return value.map(Command.connect)
        case "--print": return .print(value)
        case "--spaces": return .spaces
        case "--watch": return .watch(TimeInterval(value ?? "") ?? 30)
        case "--disconnect": return .disconnect(value)
        case "--render-preview": return value.map(Command.renderPreview)
        case "--render-live": return value.map(Command.renderLive)
        case "--version": return .version
        default: return nil
        }
    }

    @MainActor
    static func run(_ command: Command) async -> Int32 {
        do {
            switch command {
            case .version:
                Swift.print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            case .connect(let text):
                guard let url = URL(string: text) else { throw ConnectLink.Problem.notACoraLink }
                let link = try ConnectLink.parse(url)
                let paired = try await CoraClient.exchange(link, deviceName: Host.current().localizedName ?? "Mac", platform: "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) (CLI)")
                let connection = Connection(server: link.server, spaceName: link.server.host ?? "", userName: paired.user.name, email: paired.user.email, deviceId: paired.device.id)
                try Storage.save(connection, token: paired.token)
                Swift.print("Connected to \(connection.host) as \(paired.user.name) <\(paired.user.email)>, device \(paired.device.id)")
            case .spaces:
                for connection in Storage.loadConnections() { Swift.print("\(connection.server.absoluteString) \(connection.spaceName) as \(connection.userName)") }
            case .print(let space):
                let (client, _) = try connected(space)
                Swift.print(describe(try await client.snapshot()), terminator: "")
            case .watch(let seconds):
                let (client, _) = try connected()
                let snapshot = try await client.snapshot()
                let names = Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.id, $0.name) })
                let watcher = Task {
                    for try await event in client.events() {
                        switch (event.type, event.event) {
                        case ("hello", _): Swift.print("live: connected")
                        case ("trace", "start"): Swift.print("start \(names[event.trace?.agentId ?? ""] ?? "?") \(event.trace?.id ?? "")")
                        case ("trace", "step"):
                            guard let step = event.step else { continue }
                            Swift.print("step \(names[event.agentId] ?? "?") \(event.traceId) [\(step.kind.rawValue)] \(step.headline.replacingOccurrences(of: "\n", with: " ").prefix(200))")
                        case ("trace", "end"): Swift.print("end \(names[event.trace?.agentId ?? ""] ?? "?") \(event.trace?.id ?? "") \(event.trace?.status ?? "")")
                        case ("access-revoked", _): Swift.print("live: access revoked"); return
                        default: Swift.print("event \(event.type)")
                        }
                        fflush(stdout)
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                watcher.cancel()
            case .disconnect(let space):
                if let connection = pick(space) {
                    if let token = Storage.token(for: connection) { try? await CoraClient(server: connection.server, token: token).signOut() }
                    Storage.forget(connection)
                    Swift.print("Disconnected from \(connection.host)")
                } else { Swift.print("Not connected") }
            case .renderPreview(let directory):
                try render(store: SpaceStore(preview: Samples.snapshot, pins: ["sub_codex", "sub_claude", "sub_claude_buzz", "sub_grok", "provider_deepseek"], history: Samples.history), selection: Samples.selection(), directory: directory, steps: Samples.steps)
            case .renderLive(let directory):
                guard let connection = Storage.loadConnection() else { throw ClientError.unauthorized("Not connected: run --connect with a link from the panel.") }
                let store = SpaceStore(connection: connection)
                store.start()
                await store.refresh()
                guard let snapshot = store.snapshot else { throw ClientError.invalidResponse }
                let selection = LiveSelection()
                selection.agentId = snapshot.working.first?.id ?? snapshot.agents.first?.id
                for agent in snapshot.agents { for live in agent.live { await store.loadTrace(live.traceId) } }
                if let agent = snapshot.agent(selection.agentId ?? ""), let thread = agent.threads.first {
                    selection.thread = thread
                    selection.threadDetail = await store.loadThread(thread.id)
                }
                try render(store: store, selection: selection, directory: directory, steps: [:])
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("cora: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// The space named on the command line by its address or host (`127.0.0.1:4100`), or the first one.
    static func pick(_ space: String?) -> Connection? {
        let list = Storage.loadConnections()
        guard let space, !space.isEmpty else { return list.first }
        return list.first { $0.server.absoluteString == space || $0.host == space || $0.server.absoluteString.contains(space) }
    }

    static func connected(_ space: String? = nil) throws -> (CoraClient, Connection) {
        guard let connection = pick(space) else { throw ClientError.unauthorized("Not connected: run --connect with a link from the panel.") }
        guard let token = Storage.token(for: connection) else { throw ClientError.unauthorized("No token in the Keychain for \(connection.host).") }
        return (CoraClient(server: connection.server, token: token), connection)
    }

    static func describe(_ snapshot: Snapshot) -> String {
        var out = "\(snapshot.space.name) (\(snapshot.space.origin)) as \(snapshot.user.name) [\(snapshot.user.role)]\n"
        out += "Agents: \(snapshot.agents.count), working: \(snapshot.working.count)\n"
        for agent in snapshot.agents {
            let u = agent.usage
            out += "- \(agent.name) [\(agent.state.rawValue)] \(agent.model) today \(Format.tokens(u.today.total)) (\(u.today.turns) turns), 7d \(Format.tokens(u.week.total)), 30d \(Format.tokens(u.month.total))\n"
            for live in agent.live {
                out += "    live \(live.traceId) \(live.threadName.isEmpty ? live.channelId : live.threadName): \(live.lastStep.map { "[\($0.kind.rawValue)] \($0.headline.prefix(120))" } ?? "")\n"
            }
            for thread in agent.threads.prefix(5) {
                out += "    thread \(thread.name) [\(thread.status)] \(thread.reasoning.prefix(100))\n"
            }
            let accounts = snapshot.accounts(of: agent).map { Providers.name($0.provider) + ($0.email.isEmpty ? "" : " " + $0.email) }
            if !accounts.isEmpty { out += "    runs on \(accounts.joined(separator: ", "))\n" }
        }
        out += "Accounts: \(snapshot.accounts.count)\n"
        for account in snapshot.accounts {
            out += "- \(Providers.name(account.provider)) \(account.email.isEmpty ? account.label : account.email) \(account.plan) used by \(account.agentIds.compactMap { snapshot.agent($0)?.name }.joined(separator: ", "))\n"
            for window in account.usage?.windows ?? [] {
                out += "    \(window.kind.rawValue)\(window.group.isEmpty ? "" : " " + window.group): \(Format.percent(window.remainingPercent)) left\(window.resetsAt.map { ", resets in " + Format.countdown(to: $0, italian: false) } ?? "")\n"
            }
            for balance in account.usage?.balances ?? [] { out += "    balance \(balance.kind): \(balance.amount) \(balance.currency)\n" }
            if (account.usage?.windows ?? []).isEmpty && (account.usage?.balances ?? []).isEmpty { out += "    no reading (\(account.usage?.issue ?? account.usage?.state ?? "none"))\n" }
        }
        return out
    }

    /// Draws the popover and the live window as they appear on screen, in light and dark.
    @MainActor
    static func render(store: SpaceStore, selection: LiveSelection, directory: String, steps: [String: [Step]]) throws {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (traceId, list) in steps { for step in list { store.receive(ServerEvent.step(traceId: traceId, agentId: store.snapshot?.agents.first { $0.live.contains { $0.traceId == traceId } }?.id ?? "", step: step)) } }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for tab in PopoverTab.allCases {
                let popover = PopoverView(store: store, tab: tab).environment(\.isStaticPreview, true)
                try snapshot(popover, width: 360, height: nil, appearance: appearance, to: folder.appendingPathComponent("popover-\(tab.rawValue)-\(name).png"))
            }
            for tab in PopoverTab.allCases {
                try live(PopoverView(store: store, tab: tab), appearance: appearance, to: folder.appendingPathComponent("popover-live-\(tab.rawValue)-\(name).png"), label: "popover \(tab.rawValue) \(name)")
            }
            store.expanded = Set(["sub_claude", "provider_deepseek"])
            try snapshot(PopoverView(store: store, tab: .subscriptions).environment(\.isStaticPreview, true), width: 360, height: nil, appearance: appearance,
                         to: folder.appendingPathComponent("popover-subscriptions-expanded-\(name).png"))
            try live(PopoverView(store: store, tab: .subscriptions), appearance: appearance, to: folder.appendingPathComponent("popover-live-subscriptions-expanded-\(name).png"), label: "popover subscriptions expanded \(name)")
            store.expanded = []
            try snapshot(MenuBarStrip(store: store), width: 520, height: 26, appearance: appearance, to: folder.appendingPathComponent("menubar-\(name).png"))
            if let id = selection.agentId, let agent = store.snapshot?.agent(id) {
                let detail = AgentDetail(store: store, selection: selection, agent: agent).environment(\.isStaticPreview, true)
                try snapshot(detail, width: 760, height: nil, appearance: appearance, to: folder.appendingPathComponent("agent-\(name).png"))
            }
            let window = LiveWindow(store: store, selection: selection)
            try snapshot(window, width: 1000, height: 700, appearance: appearance, to: folder.appendingPathComponent("window-\(name).png"))
            let agent = selection.agentId
            selection.agentId = LiveSelection.tokens
            try snapshot(LiveWindow(store: store, selection: selection), width: 1000, height: 700, appearance: appearance, to: folder.appendingPathComponent("window-tokens-\(name).png"))
            for (label, width, height) in [("narrow", CGFloat(660), CGFloat(760)), ("wide", CGFloat(1440), CGFloat(900))] {
                try snapshot(LiveWindow(store: store, selection: selection), width: width, height: height, appearance: appearance, to: folder.appendingPathComponent("window-tokens-\(label)-\(name).png"))
            }
            for width in [CGFloat(460), 760, 1200] {
                try snapshot(TokensPage(store: store, selection: selection, snapshot: store.snapshot!).environment(\.isStaticPreview, true), width: width, height: nil, appearance: appearance,
                             to: folder.appendingPathComponent("tokens-page-\(Int(width))-\(name).png"))
            }
            selection.agentId = agent
            var other = store.snapshot!
            other.space = .init(name: "Dopamina", origin: "https://dopamina.usecora.space")
            other.agents = Array(other.agents.prefix(2))
            let spaces = Spaces(stores: [store, SpaceStore(preview: other)])
            try snapshot(PopoverView(store: store, spaces: spaces, tab: .agents).environment(\.isStaticPreview, true), width: 360, height: nil, appearance: appearance,
                         to: folder.appendingPathComponent("popover-spaces-\(name).png"))
            selection.agentId = LiveSelection.tokens
            try snapshot(LiveWindow(store: store, selection: selection, spaces: spaces), width: 1000, height: 700, appearance: appearance, to: folder.appendingPathComponent("window-spaces-\(name).png"))
            spaces.beginAdding()
            try snapshot(PopoverView(store: spaces.current, spaces: spaces, tab: .agents).environment(\.isStaticPreview, true), width: 360, height: nil, appearance: appearance,
                         to: folder.appendingPathComponent("popover-spaces-adding-\(name).png"))
            selection.agentId = agent
        }
        Swift.print("Rendered into \(folder.path)")
    }

    /// The popover as the status item shows it: an NSHostingController sized by SwiftUI, scroll view included.
    @MainActor
    static func live<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL, label: String) throws {
        let controller = NSHostingController(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        controller.sizingOptions = [.preferredContentSize]
        controller.view.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.borderless]
        window.appearance = NSAppearance(named: appearance)
        window.orderBack(nil)
        for _ in 0..<10 { controller.view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        let hosting = controller.view
        Swift.print("\(label): window \(Int(window.frame.width))x\(Int(window.frame.height)), fitting \(Int(hosting.fittingSize.width))x\(Int(hosting.fittingSize.height)), preferred \(Int(controller.preferredContentSize.width))x\(Int(controller.preferredContentSize.height)), sizingOptions \(controller.sizingOptions.rawValue)")
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw ClientError.invalidResponse }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ClientError.invalidResponse }
        try png.write(to: url)
        window.orderOut(nil)
    }

    @MainActor
    static func snapshot<V: View>(_ view: V, width: CGFloat, height: CGFloat?, appearance: NSAppearance.Name, to url: URL) throws {
        let hosting = NSHostingView(rootView: view.frame(width: width, alignment: .top).background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: appearance)
        let fitting = hosting.fittingSize
        let size = NSSize(width: width, height: height ?? max(100, min(fitting.height, 4000)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        for _ in 0..<10 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw ClientError.invalidResponse }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ClientError.invalidResponse }
        try png.write(to: url)
        window.orderOut(nil)
    }
}

extension ServerEvent {
    static func step(traceId: String, agentId: String, step: Step) -> ServerEvent {
        var payload: [String: Any] = ["type": "trace", "event": "step", "traceId": traceId, "agentId": agentId]
        var fields: [String: Any] = ["type": step.kind.rawValue, "text": step.text, "name": step.name, "result": step.result]
        if let at = step.at { fields["at"] = at.timeIntervalSince1970 * 1000 }
        payload["step"] = fields
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return ServerEvent.decode(String(decoding: data, as: UTF8.self))!
    }
}
