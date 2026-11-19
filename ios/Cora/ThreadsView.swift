import CoraKit
import SwiftUI

/// The latest threads of every agent, most recent first.
struct ThreadsView: View {
    @ObservedObject var store: SpaceStore
    @State private var query = ""

    var body: some View {
        Loaded(store: store) { snapshot in
            List {
                let all = Self.entries(snapshot)
                let list = all.filter { query.isEmpty || $0.thread.name.localizedCaseInsensitiveContains(query) || $0.agents.contains { $0.name.localizedCaseInsensitiveContains(query) } }
                if all.isEmpty { Placeholder(text: String(localized: "No threads yet.")) }
                ForEach(list, id: \.thread.id) { entry in
                    NavigationLink { ThreadDetailView(store: store, thread: entry.thread) } label: { ThreadRow(thread: entry.thread, agents: entry.agents, store: store) }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: Text("Search threads"))
            .refreshable { await store.refresh() }
        }
        .navigationTitle("Threads")
        .navigationDestination(for: ThreadRoute.self) { route in
            if let snapshot = store.snapshot, let entry = Self.entries(snapshot).first(where: { $0.thread.id == route.id }) {
                ThreadDetailView(store: store, thread: entry.thread)
            }
        }
    }

    /// One entry per thread, with every agent in it; the newest activity first.
    static func entries(_ snapshot: Snapshot) -> [(thread: ThreadInfo, agents: [Agent])] {
        var order: [String] = []
        var map: [String: (thread: ThreadInfo, agents: [Agent])] = [:]
        for agent in snapshot.agents {
            for thread in agent.threads {
                if var entry = map[thread.id] {
                    entry.agents.append(agent)
                    if (thread.lastAt ?? .distantPast) > (entry.thread.lastAt ?? .distantPast) { entry.thread = thread }
                    map[thread.id] = entry
                } else {
                    map[thread.id] = (thread, [agent]); order.append(thread.id)
                }
            }
        }
        return order.compactMap { map[$0] }.sorted { ($0.thread.lastAt ?? .distantPast) > ($1.thread.lastAt ?? .distantPast) }
    }
}

struct ThreadRow: View {
    let thread: ThreadInfo
    let agents: [Agent]
    @ObservedObject var store: SpaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                HStack(spacing: -6) { ForEach(agents.prefix(3)) { AgentAvatar(agent: $0, url: store.avatarURL($0), size: 20) } }
                Text(thread.name.isEmpty ? String(localized: "Untitled thread") : thread.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let at = thread.lastAt { Text(Format.ago(at)).font(.caption2).foregroundStyle(.secondary) }
            }
            let runs = store.liveIn(thread.id)
            if !runs.isEmpty {
                LiveNowLine(runs: runs)
            } else if !thread.reasoning.isEmpty {
                Text(thread.reasoning).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Opens one thread from a navigation path, as the screenshots do.
struct ThreadRoute: Hashable { let id: String }

/// A thread's turns: the ones running now step by step from the stream, then the recent ones, read again whenever a turn starts or ends.
struct ThreadDetailView: View {
    @ObservedObject var store: SpaceStore
    let thread: ThreadInfo
    @State private var detail: ThreadDetail?
    @State private var loaded = false

    var body: some View {
        let runs = store.liveIn(thread.id)
        let running = Set(runs.map(\.id))
        List {
            if let url = URL(string: thread.link), !thread.link.isEmpty {
                Link(destination: url) { Label("Open the thread", systemImage: "arrow.up.right.square") }
            }
            ForEach(runs) { run in
                Section {
                    LiveTurnView(store: store, live: run.live)
                } header: {
                    HStack(spacing: 6) {
                        LiveDot(size: 7)
                        Text(String(localized: "\(run.agent.name) is working"))
                        Spacer()
                        if let start = run.live.startedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Format.elapsed(since: start, now: context.date)).monospacedDigit()
                            }
                        }
                    }
                }
            }
            if let detail {
                let finished = detail.traces.filter { !running.contains($0.id) }
                if finished.isEmpty && runs.isEmpty { Placeholder(text: String(localized: "No turns in this thread yet.")) }
                ForEach(finished) { trace in
                    Section {
                        if !trace.goal.isEmpty { Text(trace.goal).font(.footnote).foregroundStyle(.secondary).lineLimit(4) }
                        ForEach(trace.steps.suffix(40)) { StepRow(step: $0) }
                        if !trace.output.isEmpty { Text(trace.output).font(.footnote).textSelection(.enabled) }
                        if !trace.error.isEmpty { Text(trace.error).font(.footnote).foregroundStyle(.red) }
                    } header: {
                        HStack {
                            Text(trace.agentName.isEmpty ? trace.kind : trace.agentName)
                            Spacer()
                            if let at = trace.startedAt { Text(at.formatted(date: .abbreviated, time: .shortened)) }
                        }
                    }
                }
            } else if loaded {
                Placeholder(text: String(localized: "This thread could not be read."))
            } else if runs.isEmpty {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(thread.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadKey(running)) {
            if let fresh = await store.loadThread(thread.id) { detail = fresh }
            loaded = true
        }
        .refreshable { if let fresh = await store.loadThread(thread.id) { detail = fresh } }
    }

    /// Changes when a turn starts or ends here, or the thread has new activity: the finished turns are read again then.
    func reloadKey(_ running: Set<String>) -> String {
        running.sorted().joined(separator: ",") + "|" + (store.threadInfo(thread.id)?.lastAt?.timeIntervalSince1970.description ?? "")
    }
}
