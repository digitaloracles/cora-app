import CoraKit
import SwiftUI

final class LiveSelection: ObservableObject {
    @Published var agentId: String?
    @Published var thread: ThreadInfo?
    @Published var threadDetail: ThreadDetail?
    @Published var loadingThread = false

    /// What the plans unfold, kept while the window is open.
    let plans = PlanSelection()

    /// The sidebar entries of the Tokens and Plans pages, beside the agents' ids.
    static let tokens = "#tokens"
    static let plans = "#plans"
    static let questions = "#questions"

    /// What the popover passes to open the Plans page on one plan.
    static func plan(_ id: String) -> String { planPrefix + id }
    static let planPrefix = "#plan:"

    /// Shows the page an entry stands for: one plan opens the Plans page on it.
    func show(_ entry: String) {
        if entry.hasPrefix(Self.planPrefix) {
            plans.focused = String(entry.dropFirst(Self.planPrefix.count))
            agentId = Self.plans
        } else {
            agentId = entry
        }
    }
}

/// The live window: agents on the left; on the right what the selected one is doing now, its threads and its usage.
struct LiveWindow: View {
    @ObservedObject var store: SpaceStore
    @ObservedObject var selection: LiveSelection
    /// With more than one space, a picker on top of the sidebar.
    var spaces: Spaces? = nil

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.agentId) {
                if let spaces, spaces.stores.count > 1 {
                    Picker(selection: Binding(get: { spaces.stores.firstIndex { $0 === spaces.current } ?? 0 }, set: { spaces.select(spaces.stores[$0]) })) {
                        ForEach(Array(spaces.stores.enumerated()), id: \.offset) { Text($0.element.title).tag($0.offset) }
                    } label: { EmptyView() }
                    .labelsHidden().pickerStyle(.menu).padding(.bottom, 4)
                }
                Label("Tokens", systemImage: "gauge.with.dots.needle.33percent").font(.system(size: 13, weight: .medium))
                    .tag(LiveSelection.tokens)
                Label("Questions", systemImage: "questionmark.bubble").font(.system(size: 13, weight: .medium))
                    .badge(store.snapshot?.requests.count ?? 0)
                    .tag(LiveSelection.questions)
                Label("Plans", systemImage: "checklist").font(.system(size: 13, weight: .medium))
                    .badge(store.snapshot?.plans?.open.count ?? 0)
                    .tag(LiveSelection.plans)
                Section("Agents") {
                ForEach(store.snapshot?.agents ?? []) { agent in
                    HStack(spacing: 8) {
                        AgentAvatar(agent: agent, url: store.avatarURL(agent), size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.name).font(.system(size: 13, weight: .medium))
                            Text(agent.state == .working ? String(localized: "Working") : Format.model(agent.model)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(agent.id)
                }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            if selection.agentId == LiveSelection.tokens, let snapshot = store.snapshot {
                TokensPage(store: store, selection: selection, snapshot: snapshot)
            } else if selection.agentId == LiveSelection.questions, let snapshot = store.snapshot {
                QuestionsPage(store: store, snapshot: snapshot)
            } else if selection.agentId == LiveSelection.plans, let snapshot = store.snapshot {
                PlansPage(store: store, plans: selection.plans, snapshot: snapshot)
            } else if let id = selection.agentId, let agent = store.snapshot?.agent(id) {
                AgentDetail(store: store, selection: selection, agent: agent)
            } else {
                Text("Choose an agent").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onChange(of: selection.agentId) { _, _ in selection.thread = nil; selection.threadDetail = nil }
    }
}

/// The window of the space on screen; switching space starts on its Tokens page.
struct SpacesWindow: View {
    @ObservedObject var spaces: Spaces
    @ObservedObject var selection: LiveSelection
    var title: (String) -> Void = { _ in }

    var body: some View {
        LiveWindow(store: spaces.current, selection: selection, spaces: spaces)
            .id(ObjectIdentifier(spaces.current))
            .onAppear { title(spaces.current.title) }
            .onChange(of: ObjectIdentifier(spaces.current)) { _, _ in
                selection.agentId = LiveSelection.tokens
                title(spaces.current.title)
            }
            .onChange(of: spaces.current.title) { _, name in title(name) }
    }
}

/// The window's Tokens page: the subscriptions, side by side when there is room, then the panel's heatmaps of what
/// everyone and every agent spent. It follows the window's width.
struct TokensPage: View {
    @ObservedObject var store: SpaceStore
    @ObservedObject var selection: LiveSelection
    let snapshot: Snapshot
    @Environment(\.isStaticPreview) private var isStaticPreview
    @State private var width: CGFloat = 760

    var body: some View {
        if isStaticPreview { content } else { ScrollView { content } }
    }

    /// The width the content has inside the page's padding, at most 1100.
    var inner: CGFloat { max(280, min(1100, width - 40)) }

    var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Tokens").font(.system(size: 20, weight: .semibold))
            TokensSummary(store: store, snapshot: snapshot, openAgent: { selection.agentId = $0 }, showTokens: false, columns: inner >= 720 ? 2 : 1)
            UsageHeatmaps(store: store, snapshot: snapshot, width: inner, openAgent: { selection.agentId = $0 })
        }
        .frame(maxWidth: 1100, alignment: .leading)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

struct AgentDetail: View {
    @ObservedObject var store: SpaceStore
    @ObservedObject var selection: LiveSelection
    let agent: Agent
    @Environment(\.isStaticPreview) private var isStaticPreview

    var body: some View {
        if isStaticPreview { content } else { ScrollView { content } }
    }

    var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    AgentAvatar(agent: agent, url: store.avatarURL(agent), size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) { Text(agent.name).font(.system(size: 20, weight: .semibold)); StateBadge(state: agent.state) }
                        Text(Format.model(agent.model)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                UsageStrip(usage: agent.usage, accounts: store.snapshot?.accounts(of: agent) ?? [])
                if agent.live.isEmpty {
                    Text("Not working on anything right now.").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(agent.live) { live in LiveTurn(store: store, live: live, tint: Color(hex: agent.color)) }
                }
                let plans = store.snapshot?.openPlans(of: agent.id) ?? []
                if !plans.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Plans").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button(String(localized: "All plans")) { selection.agentId = LiveSelection.plans }.buttonStyle(.link).font(.system(size: 11))
                        }
                        ForEach(plans) { plan in PlanCard(store: store, plans: selection.plans, plan: plan, showAgent: false) }
                    }
                }
                ThreadList(store: store, selection: selection, agent: agent)
            }
            .padding(20)
    }
}

struct UsageStrip: View {
    let usage: AgentUsage
    let accounts: [Account]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 22) {
                figure("Today", usage.today)
                figure("7 days", usage.week)
                figure("30 days", usage.month)
                Spacer()
                DailyBars(days: usage.days).frame(width: 220, height: 38)
            }
            if !accounts.isEmpty {
                HStack(spacing: 14) {
                    ForEach(accounts) { account in
                        if let window = account.tightestWindow {
                            HStack(spacing: 6) {
                                Text(Providers.name(account.provider)).font(.system(size: 11, weight: .medium))
                                UsageBar(usedPercent: window.usedPercent, color: window.level.color).frame(width: 70)
                                Text("\(Format.percent(window.remainingPercent)) left").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            }
                        } else if let balance = account.balance {
                            HStack(spacing: 6) {
                                Text(Providers.name(account.provider)).font(.system(size: 11, weight: .medium))
                                Text(balance.text).font(.system(size: 11)).foregroundStyle(balance.isEmpty ? QuotaWindow.Level.critical.color : .secondary).monospacedDigit()
                            }
                        } else {
                            Text(Providers.name(account.provider)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    func turns(_ count: Int) -> String { count == 1 ? String(localized: "1 turn") : String(localized: "\(count) turns") }

    func figure(_ title: LocalizedStringKey, _ tokens: Tokens) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(Format.tokens(tokens.total)).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            Text("\(Format.tokens(tokens.tokensIn)) in · \(Format.tokens(tokens.tokensOut)) out · \(turns(tokens.turns))")
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
        }
    }
}

/// Tokens per day over the last 30 days, one slot per day whether or not the agent worked.
struct DailyBars: View {
    let days: [DayTokens]

    var slots: [(day: String, total: Int)] {
        let totals = Dictionary(days.map { ($0.day, $0.total) }, uniquingKeysWith: +)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let last = days.map(\.day).max().flatMap(formatter.date) ?? Date()
        let end = max(last, Date())
        return (0..<30).reversed().map { offset in
            let day = formatter.string(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: -offset, to: end)!)
            return (day, totals[day] ?? 0)
        }
    }

    var body: some View {
        let slots = self.slots
        let peak = max(1, slots.map(\.total).max() ?? 1)
        GeometryReader { proxy in
            let width = max(2, (proxy.size.width - 29 * 2) / 30)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(slots, id: \.day) { slot in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(slot.total == 0 ? Color.primary.opacity(0.09) : Color.accentColor.opacity(0.75))
                        .frame(width: width, height: slot.total == 0 ? 2 : max(3, proxy.size.height * CGFloat(slot.total) / CGFloat(peak)))
                        .help("\(slot.day): \(Format.tokens(slot.total))")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .accessibilityLabel(Text("Tokens per day"))
    }
}

/// A turn running now, with its reasoning arriving step by step.
struct LiveTurn: View {
    @ObservedObject var store: SpaceStore
    let live: LiveTrace
    let tint: Color
    @Environment(\.isStaticPreview) private var isStaticPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(live.threadName.isEmpty ? String(localized: "Working") : live.threadName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if let started = live.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Format.elapsed(since: started, now: context.date)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Text("\(Format.tokens(live.tokensIn + live.tokensOut)) tokens").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                if let url = URL(string: live.link), !live.link.isEmpty {
                    Link(destination: url) { Image(systemName: "arrow.up.forward.square") }.help(String(localized: "Open the thread"))
                }
            }
            if !live.goal.isEmpty {
                Text(live.goal).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            }
            let steps = store.stepsFor(live.traceId)
            if isStaticPreview {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(steps.suffix(8).enumerated()), id: \.offset) { _, step in StepRow(step: step) }
                    if steps.isEmpty, let last = live.lastStep { StepRow(step: last) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
            } else {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(steps.suffix(80).enumerated()), id: \.offset) { index, step in StepRow(step: step).id(index) }
                        if steps.isEmpty, let last = live.lastStep { StepRow(step: last) }
                    }
                    .padding(10)
                }
                .frame(minHeight: 140, maxHeight: 320)
                .onChange(of: steps.count) { _, count in withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(min(count, 80) - 1, anchor: .bottom) } }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.5), lineWidth: 1))
        .task(id: live.traceId) { await store.loadTrace(live.traceId) }
    }
}

struct ThreadList: View {
    @ObservedObject var store: SpaceStore
    @ObservedObject var selection: LiveSelection
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Threads").font(.system(size: 13, weight: .semibold))
            if agent.threads.isEmpty {
                Text("No recent threads.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(agent.threads.sorted { ($0.lastAt ?? .distantPast) > ($1.lastAt ?? .distantPast) }) { thread in
                VStack(alignment: .leading, spacing: 0) {
                    Button { toggle(thread) } label: { row(thread) }.buttonStyle(.plain)
                    if selection.thread?.id == thread.id { expanded }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(selection.thread?.id == thread.id ? 0.06 : 0.03)))
            }
        }
    }

    func row(_ thread: ThreadInfo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: thread.status == "active" ? "bolt.fill" : thread.listening ? "ear" : "number")
                .font(.system(size: 11)).foregroundStyle(thread.status == "active" ? .green : .secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    if let at = thread.lastAt { Text(Format.ago(at)).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                if !thread.reasoning.isEmpty {
                    Text(thread.reasoning).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(10)
        .contentShape(Rectangle())
    }

    @ViewBuilder var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            if selection.loadingThread { ProgressView().controlSize(.small) }
            if let detail = selection.threadDetail {
                if let url = URL(string: detail.thread.link), !detail.thread.link.isEmpty {
                    Link(String(localized: "Open the thread"), destination: url).font(.system(size: 11))
                }
                ForEach(detail.traces.prefix(6)) { trace in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(trace.agentName.isEmpty ? trace.agentId : trace.agentName).font(.system(size: 11, weight: .semibold))
                            Text(trace.status).font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            if let at = trace.startedAt { Text(at.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                        ForEach(Array(trace.steps.suffix(12).enumerated()), id: \.offset) { _, step in StepRow(step: step) }
                        if !trace.output.isEmpty { Text(trace.output).font(.system(size: 11)).lineLimit(4).textSelection(.enabled) }
                    }
                    Divider()
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    func toggle(_ thread: ThreadInfo) {
        if selection.thread?.id == thread.id { selection.thread = nil; selection.threadDetail = nil; return }
        selection.thread = thread; selection.threadDetail = nil; selection.loadingThread = true
        Task { @MainActor in
            let detail = await store.loadThread(thread.id)
            if selection.thread?.id == thread.id { selection.threadDetail = detail }
            selection.loadingThread = false
        }
    }
}
