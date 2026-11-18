import CoraKit
import SwiftUI

enum PopoverTab: String, CaseIterable, Identifiable {
    case agents, tokens, threads
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .agents: return "Agents"
        case .tokens: return "Tokens"
        case .threads: return "Threads"
        }
    }
}

/// The menu bar popover: the space, then three tabs. Agents with what they do now; Tokens with the subscriptions
/// (each one can be pinned to the menu bar) and each agent's usage; Threads with the latest reasoning of each thread.
struct PopoverView: View {
    @ObservedObject var store: SpaceStore
    var openAgent: (String?) -> Void = { _ in }
    @State var tab: PopoverTab = .agents
    @Environment(\.isStaticPreview) private var isStaticPreview

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let snapshot = store.snapshot {
                Picker("", selection: $tab) {
                    ForEach(PopoverTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                scrolling {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case .agents: agents(snapshot)
                        case .tokens: tokens(snapshot)
                        case .threads: threads(snapshot)
                        }
                    }
                    .padding(10)
                }
            } else {
                ConnectPanel(store: store).padding(16)
            }
        }
        .frame(width: 360)
    }

    @ViewBuilder func agents(_ snapshot: Snapshot) -> some View {
        if snapshot.agents.isEmpty {
            empty("No agents in this space for your account.")
        }
        ForEach(snapshot.agents) { agent in
            Button { openAgent(agent.id) } label: { AgentRow(agent: agent, url: store.avatarURL(agent), live: liveLine(agent)) }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder func tokens(_ snapshot: Snapshot) -> some View {
        section("Subscriptions") {
            if snapshot.accounts.isEmpty {
                empty("No subscription is linked to your agents.")
            } else {
                Text("Pin the subscriptions you want to see in the menu bar.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 2)
            }
            ForEach(snapshot.accounts) { account in
                AccountCard(account: account, agents: snapshot.agents.filter { account.agentIds.contains($0.id) },
                            pinned: store.isPinned(account), onPin: { store.togglePin(account) }, avatarURL: { store.avatarURL($0) })
            }
        }
        section("Tokens by agent") {
            HStack {
                Spacer()
                ForEach(["Today", "7 days", "30 days"], id: \.self) { Text(LocalizedStringKey($0)).frame(width: 58, alignment: .trailing) }
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 10)
            ForEach(snapshot.agents.sorted { $0.usage.month.total > $1.usage.month.total }) { agent in
                Button { openAgent(agent.id) } label: {
                    HStack(spacing: 8) {
                        AgentAvatar(agent: agent, url: store.avatarURL(agent), size: 20)
                        Text(agent.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        ForEach(Array([agent.usage.today, agent.usage.week, agent.usage.month].enumerated()), id: \.offset) { _, value in
                            Text(Format.tokens(value.total)).font(.system(size: 12)).monospacedDigit().frame(width: 58, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder func threads(_ snapshot: Snapshot) -> some View {
        let list = ThreadEntry.all(snapshot)
        if list.isEmpty { empty("No threads yet.") }
        ForEach(list) { entry in
            Button { openAgent(entry.agents.first?.id) } label: { ThreadRow(entry: entry) }.buttonStyle(.plain)
        }
    }

    func empty(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 2)
    }

    /// A static render has no scroll view: it shows the whole list.
    @ViewBuilder func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if isStaticPreview { content() } else { ScrollView { content() }.frame(maxHeight: 560) }
    }

    var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.snapshot?.space.name ?? store.connection?.spaceName ?? "Cora").font(.system(size: 13, weight: .semibold))
                if let snapshot = store.snapshot {
                    Text(subtitle(snapshot)).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Not connected").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.snapshot != nil {
                Circle().fill(store.streamOnline || isStaticPreview ? Color.green : Color.orange).frame(width: 6, height: 6)
                    .help(store.streamOnline ? String(localized: "Live") : String(localized: "Reconnecting to the live stream…"))
                Button { openAgent(nil) } label: { Image(systemName: "macwindow") }.buttonStyle(.borderless).help(String(localized: "Open the live window"))
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help(String(localized: "Refresh"))
            }
            Menu {
                if let connection = store.connection {
                    Text("Signed in as \(connection.userName)")
                    Button(String(localized: "Open the panel")) { NSWorkspace.shared.open(connection.server) }
                    Button(String(localized: "Disconnect this Mac")) { Task { await store.disconnect() } }
                    Divider()
                }
                Button(String(localized: "Quit Cora")) { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    func subtitle(_ snapshot: Snapshot) -> String {
        let working = snapshot.working.count
        let who = snapshot.user.name
        return working == 0 ? String(localized: "\(who) · nobody working") : String(localized: "\(who) · \(working) working")
    }

    func liveLine(_ agent: Agent) -> String? {
        guard let live = agent.live.first else { return nil }
        let step = store.stepsFor(live.traceId).last ?? live.lastStep
        return step?.headline.replacingOccurrences(of: "\n", with: " ")
    }

    @ViewBuilder func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 2)
            content()
        }
    }
}

struct AgentRow: View {
    let agent: Agent
    let url: URL?
    let live: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(agent: agent, url: url, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.system(size: 13, weight: .semibold))
                    StateBadge(state: agent.state)
                    Spacer(minLength: 0)
                    Text(Format.tokens(agent.usage.today.total)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .help(String(localized: "Tokens today"))
                }
                if let live, !live.isEmpty {
                    Text(live).font(.system(size: 11)).italic().foregroundStyle(.secondary).lineLimit(2)
                } else if let thread = agent.live.first?.threadName, !thread.isEmpty {
                    Text(thread).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("\(Format.model(agent.model)) · \(Format.tokens(agent.usage.week.total)) in 7 days")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(agent.state == .working ? 0.07 : 0.035)))
        .contentShape(Rectangle())
    }
}

/// Before a space is connected: the address, then the panel authorizes this Mac.
struct ConnectPanel: View {
    @ObservedObject var store: SpaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your space").font(.system(size: 13, weight: .semibold))
            Text("The panel opens in your browser. Sign in there and authorize this Mac: Cora comes back here on its own.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Space address"), text: $store.spaceInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.authorize() }
            HStack {
                Button(String(localized: "Connect")) { store.authorize() }.buttonStyle(.borderedProminent).controlSize(.small)
                switch store.phase {
                case .waitingForPanel(let host):
                    ProgressView().controlSize(.small)
                    Text("Authorize this Mac on \(host)…").font(.system(size: 11)).foregroundStyle(.secondary)
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.system(size: 11)).foregroundStyle(.secondary)
                default: EmptyView()
                }
            }
            if case .failed(let message) = store.phase {
                Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Read-only: the app never changes your agents or settings.").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

/// One thread with the agents that work in it, newest first.
struct ThreadEntry: Identifiable {
    var thread: ThreadInfo
    var agents: [Agent]
    var id: String { thread.id }

    static func all(_ snapshot: Snapshot) -> [ThreadEntry] {
        var order: [String] = [], entries: [String: ThreadEntry] = [:]
        for agent in snapshot.agents {
            for thread in agent.threads {
                if var entry = entries[thread.id] {
                    entry.agents.append(agent)
                    if (thread.lastAt ?? .distantPast) > (entry.thread.lastAt ?? .distantPast) { entry.thread = thread }
                    entries[thread.id] = entry
                } else {
                    order.append(thread.id); entries[thread.id] = ThreadEntry(thread: thread, agents: [agent])
                }
            }
        }
        return order.compactMap { entries[$0] }.sorted { ($0.thread.lastAt ?? .distantPast) > ($1.thread.lastAt ?? .distantPast) }
    }
}

struct ThreadRow: View {
    let entry: ThreadEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(active ? Color.green : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                Text(entry.thread.name.isEmpty ? entry.thread.id : entry.thread.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let at = entry.thread.lastAt { Text(Format.ago(at)).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Text(([entry.agents.map(\.name).joined(separator: ", ")] + (tokens > 0 ? [Format.tokens(tokens) + " token"] : [])).joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            if !entry.thread.reasoning.isEmpty {
                Text(entry.thread.reasoning.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 11)).italic().foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(active ? 0.07 : 0.035)))
        .contentShape(Rectangle())
    }

    var active: Bool { entry.thread.status == "active" }
    var tokens: Int { entry.thread.tokensIn + entry.thread.tokensOut }
}
