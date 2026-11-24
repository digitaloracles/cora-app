import CoraKit
import SwiftUI

/// What the plans page keeps open while the window stays up: finished plans unfolded, checklist items showing their reasoning.
final class PlanSelection: ObservableObject {
    @Published var openPlans: Set<String> = []
    @Published var openItems: Set<String> = []
    @Published var loadingItems: Set<String> = []
    /// The plan the popover asked to show: the page scrolls to it and outlines it for a moment.
    @Published var focused: String?
    @Published var query = ""
}

/// The window's Plans page: every plan in progress with its checklist, then the history of finished ones.
struct PlansPage: View {
    @ObservedObject var store: SpaceStore
    @ObservedObject var plans: PlanSelection
    let snapshot: Snapshot
    @Environment(\.isStaticPreview) private var isStaticPreview

    var body: some View {
        if isStaticPreview {
            content
        } else {
            ScrollViewReader { reader in
                ScrollView { content }
                    .onAppear { reveal(reader) }
                    .onChange(of: plans.focused) { _, _ in reveal(reader) }
            }
        }
    }

    func reveal(_ reader: ScrollViewProxy) {
        guard let id = plans.focused else { return }
        plans.query = ""
        if !(snapshot.plans?.open.contains { $0.id == id } ?? false) { plans.openPlans.insert(id) }
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.25)) { reader.scrollTo(id, anchor: .top) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if plans.focused == id { withAnimation { plans.focused = nil } } }
    }

    var content: some View {
        let searching = !plans.query.trimmingCharacters(in: .whitespaces).isEmpty
        let open = Plan.matching(snapshot.plans?.open ?? [], plans.query)
        let history = Plan.matching(store.planHistory, plans.query)
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Text("Plans").font(.system(size: 20, weight: .semibold))
                Spacer()
                if snapshot.plans != nil {
                    Text("\(open.count) in progress · \(history.count) finished").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if snapshot.plans != nil {
                SearchField(query: $plans.query, prompt: String(localized: "Search plans")).frame(maxWidth: 360)
            }
            if snapshot.plans == nil {
                Text("This space does not list plans yet: its Cora server needs an update.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("In progress").font(.system(size: 13, weight: .semibold))
                    if open.isEmpty {
                        Text(searching ? "No plan in progress matches your search." : "No plan in progress.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(open) { plan in PlanCard(store: store, plans: plans, plan: plan).id(plan.id) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("History").font(.system(size: 13, weight: .semibold))
                    if history.isEmpty {
                        Text(searching ? "No finished plan matches your search." : "No finished plans yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(history.enumerated()), id: \.element.id) { index, plan in
                                if index > 0 { Divider().padding(.leading, 38) }
                                PlanHistoryRow(store: store, plans: plans, plan: plan).id(plan.id)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                    }
                    if store.hasOlderPlans {
                        Button {
                            Task { await store.loadOlderPlans() }
                        } label: {
                            HStack(spacing: 6) {
                                if store.loadingOlderPlans { ProgressView().controlSize(.small) }
                                Text("Show older plans")
                            }
                        }
                        .controlSize(.small)
                        .disabled(store.loadingOlderPlans)
                    }
                }
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An open plan: who runs it and where, how far it is, the blocker if any, and its checklist.
struct PlanCard: View {
    @ObservedObject var store: SpaceStore
    @ObservedObject var plans: PlanSelection
    let plan: Plan
    /// Inside an agent's page the agent is already on screen.
    var showAgent = true
    /// In the menu bar popover: a smaller face and tighter spacing for its narrow width.
    var compact = false
    /// In the menu bar popover the card is only its head: a click opens the window on the whole plan.
    var open: (() -> Void)? = nil

    var body: some View {
        let tint = plan.status == .blocked ? Color.orange : PlanAgentFace.tint(plan, store.snapshot)
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(alignment: .top, spacing: compact ? 8 : 10) {
                if showAgent { PlanAgentFace(store: store, plan: plan, size: compact ? 24 : 28) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(PlanText.place(plan, agent: showAgent)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                PlanStatusBadge(status: plan.status)
                PlanThreadLink(plan: plan)
            }
            HStack(spacing: 8) {
                PlanProgress(progress: plan.progress, tint: tint).frame(maxWidth: 260)
                Text(PlanText.count(plan)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if let at = plan.updatedAt { Text(Format.ago(at)).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if plan.status == .blocked && !plan.blockedReason.isEmpty {
                Label(plan.blockedReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
            }
            if open == nil && plan.allowsOwnerClose {
                Button("Close plan", role: .destructive) { store.planToClose = plan }
                    .disabled(store.closingPlans.contains(plan.id))
                    .confirmationDialog("Close this plan?", isPresented: Binding(
                        get: { store.planToClose?.id == plan.id },
                        set: { if !$0 && store.planToClose?.id == plan.id { store.planToClose = nil } }
                    ), titleVisibility: .visible, presenting: store.planToClose) { selected in
                        Button("Confirm closure", role: .destructive) {
                            Task { await store.closePlan(selected) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: { selected in
                        Text(selected.name)
                    }
                if let message = store.closeErrors[plan.id] {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            if open == nil { PlanChecklist(store: store, plans: plans, plan: plan) }
        }
        .padding(compact ? 10 : 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(focused ? 1 : 0.35), lineWidth: focused ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { open?() }
        .help(open == nil ? "" : String(localized: "Open the plan in the window"))
    }

    var focused: Bool { open == nil && plans.focused == plan.id }
}

/// A finished plan in one line; a click unfolds its checklist.
struct PlanHistoryRow: View {
    @ObservedObject var store: SpaceStore
    @ObservedObject var plans: PlanSelection
    let plan: Plan
    /// In the menu bar popover the icon already says completed or closed, and the time is relative.
    var compact = false
    /// In the menu bar popover a click opens the window on the plan instead of unfolding it here.
    var openInWindow: (() -> Void)? = nil

    var body: some View {
        let open = plans.openPlans.contains(plan.id)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let openInWindow { openInWindow() } else if open { plans.openPlans.remove(plan.id) } else { plans.openPlans.insert(plan.id) }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: plan.status == .completed ? "checkmark.seal.fill" : "xmark.circle")
                        .font(.system(size: 13)).foregroundStyle(plan.status == .completed ? Color.green : Color.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(PlanText.place(plan, agent: true) + " · " + PlanText.count(plan)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if !compact { PlanStatusBadge(status: plan.status) }
                    if let at = plan.updatedAt {
                        Text(compact ? Format.ago(at) : at.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open && openInWindow == nil ? 90 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open && openInWindow == nil {
                VStack(alignment: .leading, spacing: 8) {
                    PlanThreadLink(plan: plan, label: true)
                    PlanChecklist(store: store, plans: plans, plan: plan)
                }
                .padding(.leading, 38).padding(.trailing, 10).padding(.bottom, 10)
            }
        }
    }
}

/// The checklist in order; items with linked reasoning open to show it.
struct PlanChecklist: View {
    @ObservedObject var store: SpaceStore
    @ObservedObject var plans: PlanSelection
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(plan.items.enumerated()), id: \.element.id) { index, item in
                let state = plan.state(of: index)
                let reasoned = plan.reasoned(item)
                let key = store.reasoningKey(plan, item)
                let open = plans.openItems.contains(key)
                VStack(alignment: .leading, spacing: 4) {
                    Button { toggle(item, key: key) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: PlanText.symbol(state)).font(.system(size: 11)).foregroundStyle(PlanText.tint(state)).frame(width: 14)
                            Text("\(index + 1). \(item.text)")
                                .font(.system(size: 12, weight: state == .current || state == .blocked ? .semibold : .regular))
                                .foregroundStyle(state == .done || state == .dropped ? Color.secondary : Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if let reasoned {
                                Text(reasoned.count == 1 ? String(localized: "1 step") : String(localized: "\(reasoned.count) steps"))
                                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(open ? 90 : 0))
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(reasoned == nil)
                    if open {
                        VStack(alignment: .leading, spacing: 2) {
                            if plans.loadingItems.contains(key) { ProgressView().controlSize(.small) }
                            let steps = store.planReasoning[key] ?? []
                            ForEach(Array(steps.suffix(60).enumerated()), id: \.offset) { _, step in StepRow(step: step) }
                            if steps.isEmpty && !plans.loadingItems.contains(key) {
                                Text("No reasoning could be read for this step.").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
                        .padding(.leading, 22)
                    }
                }
            }
        }
    }

    func toggle(_ item: Plan.Item, key: String) {
        if plans.openItems.contains(key) { plans.openItems.remove(key); return }
        plans.openItems.insert(key)
        guard store.planReasoning[key] == nil else { return }
        plans.loadingItems.insert(key)
        Task { @MainActor in
            await store.loadPlanReasoning(plan, item)
            plans.loadingItems.remove(key)
        }
    }
}

struct PlanStatusBadge: View {
    let status: Plan.Status

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
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

struct PlanThreadLink: View {
    let plan: Plan
    var label = false

    var body: some View {
        if let url = URL(string: plan.link), !plan.link.isEmpty {
            if label {
                Link(String(localized: "Open the thread"), destination: url).font(.system(size: 11))
            } else {
                Link(destination: url) { Image(systemName: "arrow.up.forward.square") }.help(String(localized: "Open the thread"))
            }
        }
    }
}

/// The agent's face when it is in the snapshot, else its initial on its color.
struct PlanAgentFace: View {
    @ObservedObject var store: SpaceStore
    let plan: Plan
    var size: CGFloat = 22

    var body: some View {
        if let agent = store.snapshot?.agent(plan.agentId) {
            AgentAvatar(agent: agent, url: store.avatarURL(agent), size: size, ring: false)
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
