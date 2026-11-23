import CoraKit
import SwiftUI

/// Every plan of the space: the ones in progress with their progress and blocker, then the finished ones, newest first.
struct PlansView: View {
    @ObservedObject var store: SpaceStore
    @State private var query = ""

    var body: some View {
        Loaded(store: store) { snapshot in
            List {
                if snapshot.plans == nil {
                    Placeholder(text: String(localized: "This space does not list plans yet: its Cora server needs an update."))
                } else {
                    let open = (snapshot.plans?.open ?? []).filter(matches)
                    let history = store.planHistory.filter(matches)
                    Section {
                        if open.isEmpty { Placeholder(text: String(localized: "No plan in progress.")) }
                        ForEach(open) { plan in
                            NavigationLink { PlanDetailView(store: store, planId: plan.id) } label: { PlanRow(store: store, plan: plan) }
                        }
                    } header: {
                        Text("In progress")
                    }
                    Section {
                        if history.isEmpty { Placeholder(text: String(localized: "No finished plans yet.")) }
                        ForEach(history) { plan in
                            NavigationLink { PlanDetailView(store: store, planId: plan.id) } label: { PlanHistoryRow(store: store, plan: plan) }
                        }
                        if store.hasOlderPlans {
                            Button {
                                Task { await store.loadOlderPlans() }
                            } label: {
                                HStack(spacing: 8) {
                                    Text("Show older plans")
                                    if store.loadingOlderPlans { Spacer(); ProgressView() }
                                }
                            }
                            .disabled(store.loadingOlderPlans)
                        }
                    } header: {
                        Text("History")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: Text("Search plans"))
            .refreshable { await store.refresh() }
        }
        .navigationTitle("Plans")
        .navigationDestination(for: PlanRoute.self) { PlanDetailView(store: store, planId: $0.id) }
    }

    func matches(_ plan: Plan) -> Bool {
        query.isEmpty || plan.name.localizedCaseInsensitiveContains(query) || plan.agentName.localizedCaseInsensitiveContains(query)
            || plan.threadName.localizedCaseInsensitiveContains(query) || plan.items.contains { $0.text.localizedCaseInsensitiveContains(query) }
    }
}

/// Opens one plan from a navigation path, as the screenshots do.
struct PlanRoute: Hashable { let id: String }

/// An open plan in a list: who runs it and where, the current step, how far it is, the blocker if any.
struct PlanRow: View {
    @ObservedObject var store: SpaceStore
    let plan: Plan
    /// Inside an agent's page the agent is already on screen.
    var showAgent = true

    var body: some View {
        let tint = plan.status == .blocked ? Color.orange : PlanAgentFace.tint(plan, store.snapshot)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                if showAgent { PlanAgentFace(store: store, plan: plan, size: 28) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(PlanText.place(plan, agent: showAgent)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                PlanStatusBadge(status: plan.status)
            }
            if let current = plan.current {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: PlanText.symbol(plan.state(of: plan.done))).font(.caption).foregroundStyle(PlanText.tint(plan.state(of: plan.done)))
                    Text(current.text).font(.footnote).lineLimit(2)
                }
            }
            HStack(spacing: 8) {
                PlanProgress(progress: plan.progress, tint: tint)
                Text(PlanText.count(plan)).font(.caption2).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                if let at = plan.updatedAt { Text(Format.ago(at)).font(.caption2).foregroundStyle(.secondary).fixedSize() }
            }
            if plan.status == .blocked && !plan.blockedReason.isEmpty {
                Label(plan.blockedReason, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            let runs = store.liveIn(plan.channelId, agentId: plan.agentId)
            if !runs.isEmpty { LiveNowLine(runs: runs) }
        }
        .padding(.vertical, 3)
    }
}

/// A finished plan in one line.
struct PlanHistoryRow: View {
    @ObservedObject var store: SpaceStore
    let plan: Plan

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: plan.status == .completed ? "checkmark.seal.fill" : "xmark.circle")
                .font(.subheadline).foregroundStyle(plan.status == .completed ? Color.green : Color.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.name).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(PlanText.place(plan, agent: true)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(plan.updatedAt.map { PlanText.count(plan) + " · " + $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? PlanText.count(plan))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 6)
            PlanStatusBadge(status: plan.status)
        }
        .padding(.vertical, 2)
    }
}

/// One plan whole: where it runs, its blocker, the checklist in order; a step with linked reasoning opens to show it.
struct PlanDetailView: View {
    @ObservedObject var store: SpaceStore
    let planId: String
    @State private var openItems: Set<String> = Set(ProcessInfo.processInfo.environment["CORA_DEMO_PLAN_ITEM"].map { [$0] } ?? [])
    @State private var loadingItems: Set<String> = []

    var plan: Plan? {
        (store.snapshot?.plans?.open ?? []).first { $0.id == planId } ?? store.planHistory.first { $0.id == planId }
    }

    var body: some View {
        if let plan {
            let tint = plan.status == .blocked ? Color.orange : PlanAgentFace.tint(plan, store.snapshot)
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        PlanAgentFace(store: store, plan: plan, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(plan.name).font(.headline)
                            Text(PlanText.place(plan, agent: true)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                    HStack(spacing: 8) {
                        PlanStatusBadge(status: plan.status)
                        PlanProgress(progress: plan.progress, tint: tint)
                        Text(PlanText.count(plan)).font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    }
                    if plan.status == .blocked && !plan.blockedReason.isEmpty {
                        Label(plan.blockedReason, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                    }
                    if let url = URL(string: plan.link), !plan.link.isEmpty {
                        Link(destination: url) { Label("Open the thread", systemImage: "arrow.up.right.square") }
                    }
                }
                Section {
                    ForEach(Array(plan.items.enumerated()), id: \.element.id) { index, item in
                        checklistItem(plan, index: index, item: item)
                    }
                } header: {
                    HStack {
                        Text("Checklist")
                        Spacer()
                        if let at = plan.updatedAt { Text(Format.ago(at)) }
                    }
                }
                ForEach(store.liveIn(plan.channelId, agentId: plan.agentId)) { run in
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
            }
            .listStyle(.insetGrouped)
            .navigationTitle(plan.name)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh() }
            .task(id: plan.updatedAt) { for key in openItems { if let item = plan.items.first(where: { store.reasoningKey(plan, $0) == key || $0.id == key }) { await load(plan, item) } } }
        } else if store.snapshot == nil {
            ProgressView("Reading the space…")
        } else {
            ContentUnavailableView("Plan not found", systemImage: "checklist")
        }
    }

    @ViewBuilder
    func checklistItem(_ plan: Plan, index: Int, item: Plan.Item) -> some View {
        let state = plan.state(of: index)
        let reasoned = plan.reasoned(item)
        let key = store.reasoningKey(plan, item)
        let open = openItems.contains(key) || openItems.contains(item.id)
        Button { toggle(plan, item, key: key, open: open) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: PlanText.symbol(state)).foregroundStyle(PlanText.tint(state)).frame(width: 18)
                Text("\(index + 1). \(item.text)")
                    .font(.subheadline.weight(state == .current || state == .blocked ? .semibold : .regular))
                    .foregroundStyle(state == .done || state == .dropped ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let reasoned {
                    Text(reasoned.count == 1 ? String(localized: "1 step") : String(localized: "\(reasoned.count) steps"))
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reasoned == nil)
        if open {
            if loadingItems.contains(key) { ProgressView().frame(maxWidth: .infinity) }
            let steps = store.planReasoning[key] ?? []
            ForEach(Array(steps.suffix(60).enumerated()), id: \.offset) { _, step in StepRow(step: step).padding(.leading, 28) }
            if steps.isEmpty && !loadingItems.contains(key) {
                Placeholder(text: String(localized: "No reasoning could be read for this step.")).padding(.leading, 28)
            }
        }
    }

    func toggle(_ plan: Plan, _ item: Plan.Item, key: String, open: Bool) {
        if open { openItems.remove(key); openItems.remove(item.id); return }
        openItems.insert(key)
        Task { await load(plan, item) }
    }

    func load(_ plan: Plan, _ item: Plan.Item) async {
        let key = store.reasoningKey(plan, item)
        guard store.planReasoning[key] == nil else { return }
        loadingItems.insert(key)
        await store.loadPlanReasoning(plan, item)
        loadingItems.remove(key)
    }
}

struct PlanStatusBadge: View {
    let status: Plan.Status

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .fixedSize()
    }

    var label: String {
        switch status {
        case .active: return String(localized: "In progress")
        case .blocked: return String(localized: "Blocked")
        case .completed: return String(localized: "Completed")
        case .closed: return String(localized: "Closed")
        }
    }

    var color: Color {
        switch status {
        case .active: return .green
        case .blocked: return .orange
        case .completed: return .green.opacity(0.55)
        case .closed: return Color.secondary.opacity(0.4)
        }
    }
}

/// The plan's progress: a 5 pt capsule like the usage bars, filled with the agent's color.
struct PlanProgress: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                if progress > 0 { Capsule().fill(tint).frame(width: max(5, proxy.size.width * progress)) }
            }
        }
        .frame(height: 5)
        .accessibilityLabel(Text("\(Int((progress * 100).rounded()))%"))
    }
}

/// The agent's face when it is in the snapshot, else its initial on its color.
struct PlanAgentFace: View {
    @ObservedObject var store: SpaceStore
    let plan: Plan
    var size: CGFloat = 22

    var body: some View {
        if let agent = store.snapshot?.agent(plan.agentId) {
            AgentAvatar(agent: agent, url: store.avatarURL(agent), size: size)
        } else {
            let tint = Color(hex: plan.color.isEmpty ? "#f2a93b" : plan.color)
            ZStack {
                Circle().fill(tint.opacity(0.22))
                Text(String(plan.agentName.prefix(1)).uppercased()).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: size, height: size)
        }
    }

    static func tint(_ plan: Plan, _ snapshot: Snapshot?) -> Color {
        Color(hex: snapshot?.agent(plan.agentId)?.color ?? (plan.color.isEmpty ? "#f2a93b" : plan.color))
    }
}

enum PlanText {
    /// `Buzz · Thread name`, or just the thread inside the agent's own page.
    static func place(_ plan: Plan, agent: Bool) -> String {
        let thread = plan.threadName.isEmpty ? String(localized: "Thread") : plan.threadName
        return agent ? "\(plan.agentName.isEmpty ? plan.agentId : plan.agentName) · \(thread)" : thread
    }

    /// `2 of 5 steps`.
    static func count(_ plan: Plan) -> String { String(localized: "\(min(plan.done, plan.items.count)) of \(plan.items.count) steps") }

    static func symbol(_ state: Plan.ItemState) -> String {
        switch state {
        case .done: return "checkmark.circle.fill"
        case .current: return "arrow.right.circle.fill"
        case .blocked: return "exclamationmark.circle.fill"
        case .pending: return "circle"
        case .dropped: return "minus.circle"
        }
    }

    static func tint(_ state: Plan.ItemState) -> Color {
        switch state {
        case .done: return .green
        case .current: return .accentColor
        case .blocked: return .orange
        case .pending: return .secondary
        case .dropped: return Color.secondary.opacity(0.5)
        }
    }
}
