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
            if !thread.reasoning.isEmpty {
                Text(thread.reasoning).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A thread's recent turns, each with its steps and output.
struct ThreadDetailView: View {
    @ObservedObject var store: SpaceStore
    let thread: ThreadInfo
    @State private var detail: ThreadDetail?
    @State private var loaded = false

    var body: some View {
        List {
            if let url = URL(string: thread.link), !thread.link.isEmpty {
                Link(destination: url) { Label("Open the thread", systemImage: "arrow.up.right.square") }
            }
            if let detail {
                if detail.traces.isEmpty { Placeholder(text: String(localized: "No turns in this thread yet.")) }
                ForEach(detail.traces) { trace in
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
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(thread.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { detail = await store.loadThread(thread.id); loaded = true }
        .refreshable { detail = await store.loadThread(thread.id) }
    }
}
