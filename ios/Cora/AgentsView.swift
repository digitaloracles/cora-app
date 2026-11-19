import CoraKit
import SwiftUI

/// Every agent the person sees in the space: working ones first, with the step they are on.
struct AgentsView: View {
    @ObservedObject var store: SpaceStore
    @State private var query = ""

    var body: some View {
        Loaded(store: store) { snapshot in
            List {
                let list = Self.sorted(snapshot.agents.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) })
                if snapshot.agents.isEmpty { Placeholder(text: String(localized: "No agents in this space for your account.")) }
                ForEach(list) { agent in
                    NavigationLink(value: agent.id) { AgentRow(store: store, agent: agent) }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: Text("Search agents"))
            .refreshable { await store.refresh() }
        }
        .navigationTitle("Agents")
        .navigationDestination(for: String.self) { AgentDetailView(store: store, agentId: $0) }
    }

    static func sorted(_ agents: [Agent]) -> [Agent] {
        let rank: [Agent.State: Int] = [.working: 0, .listening: 1, .idle: 2, .off: 3]
        return agents.enumerated().sorted { (rank[$0.element.state] ?? 2, $0.offset) < (rank[$1.element.state] ?? 2, $1.offset) }.map(\.element)
    }
}

struct AgentRow: View {
    @ObservedObject var store: SpaceStore
    let agent: Agent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentAvatar(agent: agent, url: store.avatarURL(agent))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.body.weight(.semibold)).lineLimit(1)
                    StateBadge(state: agent.state)
                    Spacer(minLength: 4)
                    Text(Format.tokens(agent.usage.today.total)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(secondLine).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    .italic(agent.live.first?.lastStep?.kind == .thinking)
            }
        }
        .padding(.vertical, 2)
    }

    var secondLine: String {
        if let live = agent.live.first {
            if let step = live.lastStep, !step.headline.isEmpty { return step.headline }
            if !live.threadName.isEmpty { return live.threadName }
        }
        return Format.model(agent.model) + " · " + String(localized: "\(Format.tokens(agent.usage.week.total)) tokens in 7 days")
    }
}

/// One agent: usage, the subscriptions it runs on, its live turns with their steps, its threads.
struct AgentDetailView: View {
    @ObservedObject var store: SpaceStore
    let agentId: String

    var body: some View {
        if let snapshot = store.snapshot, let agent = snapshot.agent(agentId) {
            List {
                Section {
                    HStack(spacing: 14) {
                        AgentAvatar(agent: agent, url: store.avatarURL(agent), size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.name).font(.title2.weight(.semibold))
                            HStack(spacing: 6) { StateBadge(state: agent.state); Text(Format.model(agent.model)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    .padding(.vertical, 4)
                    HStack {
                        usage("Today", agent.usage.today)
                        Divider()
                        usage("7 days", agent.usage.week)
                        Divider()
                        usage("30 days", agent.usage.month)
                    }
                }
                let accounts = snapshot.accounts(of: agent)
                if !accounts.isEmpty {
                    Section("Subscriptions") {
                        ForEach(accounts) { SubscriptionRow(store: store, account: $0, title: $0.displayName) }
                    }
                }
                ForEach(agent.live) { live in
                    Section {
                        LiveTurnView(store: store, live: live)
                    } header: {
                        HStack {
                            Text(live.threadName.isEmpty ? String(localized: "Live turn") : live.threadName)
                            Spacer()
                            if let start = live.startedAt {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text(Format.elapsed(since: start, now: context.date)).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                if !agent.threads.isEmpty {
                    Section("Threads") {
                        ForEach(agent.threads) { thread in
                            NavigationLink { ThreadDetailView(store: store, thread: thread) } label: { ThreadRow(thread: thread, agents: [agent], store: store) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
        } else {
            ContentUnavailableView("Agent not found", systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    func usage(_ title: LocalizedStringKey, _ tokens: Tokens) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(Format.tokens(tokens.total)).font(.headline).monospacedDigit()
            Text("\(tokens.turns) turns").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A turn running now: goal, tokens, then every step as it arrives.
struct LiveTurnView: View {
    @ObservedObject var store: SpaceStore
    let live: LiveTrace

    var body: some View {
        if !live.goal.isEmpty {
            Text(live.goal).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
        }
        HStack {
            Text("\(Format.tokens(live.tokensIn)) in · \(Format.tokens(live.tokensOut)) out").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if let url = URL(string: live.link), !live.link.isEmpty { Link(destination: url) { Image(systemName: "arrow.up.right.square") } }
        }
        let steps = store.stepsFor(live.traceId)
        if steps.isEmpty, let last = live.lastStep {
            StepRow(step: last)
        }
        ForEach(steps.suffix(60).reversed()) { StepRow(step: $0) }
            .task(id: live.traceId) { await store.loadTrace(live.traceId) }
        if steps.isEmpty && live.lastStep == nil {
            Placeholder(text: String(localized: "Waiting for the first step…")).task(id: live.traceId) { await store.loadTrace(live.traceId) }
        }
    }
}
