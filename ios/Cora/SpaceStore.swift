import CoraKit
import Foundation

/// A turn running now, with the agent that runs it.
struct LiveRun: Identifiable {
    let agent: Agent
    let live: LiveTrace
    var id: String { live.traceId }
}

/// One space as the iPhone shows it: the last snapshot, the live steps from the event stream, the connection state.
/// Reads only, like the Mac app; the single write is signing this iPhone out.
@MainActor
final class SpaceStore: ObservableObject, Identifiable {
    enum Phase: Equatable { case connecting, ready, failed(String) }

    let id: URL
    @Published private(set) var connection: Connection
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var streamOnline = false
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var steps: [String: [Step]] = [:]
    @Published private(set) var traces: [String: TraceDetail] = [:]
    @Published private(set) var revoked = false
    /// Finished plans older than the snapshot's, read page by page when the person asks.
    @Published private(set) var olderPlans: [Plan] = []
    @Published private(set) var olderCursor: String?
    @Published private(set) var loadingOlderPlans = false
    /// The reasoning linked to checklist items, by `planId/itemId`, read when an item is opened.
    @Published private(set) var planReasoning: [String: [Step]] = [:]

    /// Questions this device is answering now, so a second press waits for the first.
    @Published private(set) var answering: Set<String> = []
    /// The last answer sent from here, shown for a moment where the question was; and why the last press failed.
    @Published private(set) var lastAnswer: (agentName: String, answer: String)?
    @Published var choiceError: String?

    private(set) var client: CoraClient?
    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pendingRefresh: Task<Void, Never>?
    private let maxSteps = 300

    init(connection: Connection) {
        self.connection = connection
        self.id = connection.server
    }

    private var demo = false

    /// Sample data and no server, for the simulator screenshots.
    init(demo snapshot: Snapshot, steps: [String: [Step]], planReasoning: [String: [Step]] = [:]) {
        let connection = Connection(server: URL(string: snapshot.space.origin)!, spaceName: snapshot.space.name, userName: snapshot.user.name, email: snapshot.user.email, deviceId: "demo")
        self.connection = connection
        id = connection.server
        self.snapshot = snapshot
        self.steps = steps
        self.planReasoning = planReasoning
        phase = .ready
        streamOnline = true
        refreshedAt = Date().addingTimeInterval(-40)
        demo = true
    }

    /// `CORA_DEMO_CHANGE=1`: two seconds in, Ada's blocked plan starts again with Ada at work, as the snapshot brings it,
    /// so the screenshots can check that rows change once and then stay still.
    private func demoChange() {
        guard ProcessInfo.processInfo.environment["CORA_DEMO_CHANGE"] == "1" else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, var next = self.snapshot else { return }
            if var board = next.plans, let at = board.open.firstIndex(where: { $0.id == "plan_ada" }) {
                board.open[at].status = .active
                board.open[at].blockedReason = ""
                board.open[at].updatedAt = Date()
                next.plans = board
                let plan = board.open[at]
                if let agent = next.agents.firstIndex(where: { $0.id == plan.agentId }), let model = next.agents.first(where: { $0.id == "ag_buzz" })?.live.first {
                    var live = model
                    live.traceId = "tr_ada"
                    live.channelId = plan.channelId
                    live.threadName = plan.threadName
                    live.startedAt = Date()
                    next.agents[agent].live = [live]
                    next.agents[agent].state = .working
                }
            }
            self.snapshot = next
        }
    }

    init(connection: Connection, token: String) {
        self.connection = connection
        self.id = connection.server
        client = CoraClient(server: connection.server, token: token)
    }

    var title: String { snapshot?.space.name ?? connection.spaceName }

    /// Starts reading: a snapshot now and every minute, and the live stream while the app is in front.
    func start() {
        if demo { demoChange(); return }
        if client == nil {
            guard let token = Storage.token(for: connection) else {
                phase = .failed(String(localized: "The access of this iPhone is missing: connect the space again."))
                return
            }
            client = CoraClient(server: connection.server, token: token)
        }
        Task { await refresh() }
        runStream()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.refresh()
            }
        }
    }

    /// Stops the stream and the polling, as when the app goes to the background.
    func pause() {
        streamTask?.cancel(); pollTask?.cancel(); pendingRefresh?.cancel()
        streamOnline = false
    }

    func signOut() async {
        pause()
        if demo { return }
        if let client { try? await client.signOut() }
        Storage.forget(connection)
        client = nil
        olderPlans = []; olderCursor = nil; planReasoning = [:]
    }

    func refresh() async {
        guard let client else { return }
        do {
            let fresh = try await client.snapshot()
            snapshot = fresh.hidingDismissed(server: client.server)
            refreshedAt = Date()
            phase = .ready
            if connection.spaceName != fresh.space.name || connection.userName != fresh.user.name {
                connection.spaceName = fresh.space.name; connection.userName = fresh.user.name
                Storage.update(connection)
            }
        } catch ClientError.unauthorized(let message) {
            revoke(message)
        } catch {
            phase = snapshot == nil ? .failed(error.localizedDescription) : .ready
        }
    }

    private func revoke(_ message: String) {
        pause()
        Storage.forget(connection)
        client = nil
        revoked = true
        phase = .failed(message.isEmpty ? String(localized: "This iPhone was disconnected from the space. Connect it again from the panel.") : message)
    }

    /// Presses one of the answers an agent offered: the agent hears it as the owner's word, and the question leaves the list.
    func answer(_ request: ChoiceRequest, index: Int) async {
        guard request.choices.indices.contains(index), !answering.contains(request.id) else { return }
        if demo {
            snapshot?.requests.removeAll { $0.id == request.id }
            lastAnswer = (request.agentName, request.choices[index])
            return
        }
        guard let client else { return }
        answering.insert(request.id)
        choiceError = nil
        defer { answering.remove(request.id) }
        do {
            let sent = try await client.answer(request, index: index)
            snapshot?.requests.removeAll { $0.id == request.id }
            lastAnswer = (request.agentName, sent.answer)
            let shown = sent.answer
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if self?.lastAnswer?.answer == shown { self?.lastAnswer = nil }
            }
        } catch {
            choiceError = error.localizedDescription
        }
        scheduleRefresh()
    }

    /// Sets a question aside: on a space that knows the route it leaves every app, otherwise only this iPhone.
    func dismiss(_ request: ChoiceRequest) async {
        guard !answering.contains(request.id) else { return }
        snapshot?.requests.removeAll { $0.id == request.id }
        choiceError = nil
        guard !demo, let client else { return }
        answering.insert(request.id)
        defer { answering.remove(request.id) }
        do {
            if try await !client.dismiss(request) { DismissedQuestions.add(request.id, server: client.server) }
        } catch {
            DismissedQuestions.add(request.id, server: client.server)
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func runStream() {
        streamTask?.cancel()
        guard let client else { return }
        streamTask = Task { [weak self] in
            var delay: UInt64 = 2
            while !Task.isCancelled {
                do {
                    for try await event in client.events() {
                        delay = 2
                        self?.receive(event)
                    }
                } catch ClientError.unauthorized(let message) {
                    self?.revoke(message); return
                } catch {}
                self?.streamOnline = false
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 60)
            }
        }
    }

    func receive(_ event: ServerEvent) {
        switch event.type {
        case "hello": streamOnline = true
        case "access-revoked": revoke("")
        case "trace":
            if event.event == "step", let step = event.step, !event.traceId.isEmpty {
                var list = steps[event.traceId] ?? traces[event.traceId]?.steps ?? []
                list.append(step)
                if list.count > maxSteps { list.removeFirst(list.count - maxSteps) }
                steps[event.traceId] = list
                updateLastStep(traceId: event.traceId, agentId: event.agentId, step: step)
            } else {
                if event.event == "end", let id = event.trace?.id { traces[id] = nil }
                scheduleRefresh()
            }
        case "subscription-usage", "agents", "agent-owners", "choice": scheduleRefresh()
        case "plan":
            if !event.planId.isEmpty { planReasoning = planReasoning.filter { !$0.key.hasPrefix(event.planId + "/") } }
            scheduleRefresh()
        default: break
        }
    }

    private func updateLastStep(traceId: String, agentId: String, step: Step) {
        guard var snapshot, let index = snapshot.agents.firstIndex(where: { $0.id == agentId }) else { return }
        if let live = snapshot.agents[index].live.firstIndex(where: { $0.traceId == traceId }) {
            snapshot.agents[index].live[live].lastStep = step
            snapshot.agents[index].live[live].stepCount += 1
        } else {
            scheduleRefresh()
        }
        if step.kind != .note { snapshot.agents[index].state = .working }
        self.snapshot = snapshot
    }

    /// The whole turn, then its new steps from the stream.
    func loadTrace(_ id: String) async {
        guard let client else { return }
        if let detail = try? await client.trace(id) {
            traces[id] = detail
            let streamed = steps[id] ?? []
            let known = Set(detail.steps.map(\.id))
            steps[id] = detail.steps + streamed.filter { !known.contains($0.id) }
        }
    }

    /// The turns running now in a thread or channel, from the snapshot the stream keeps current.
    func liveIn(_ channelId: String, agentId: String? = nil) -> [LiveRun] {
        guard let snapshot, !channelId.isEmpty else { return [] }
        return snapshot.agents.filter { agentId == nil || $0.id == agentId }.flatMap { agent in
            agent.live.filter { $0.channelId == channelId }.map { LiveRun(agent: agent, live: $0) }
        }
    }

    /// A thread as the snapshot lists it now, with its latest activity.
    func threadInfo(_ id: String) -> ThreadInfo? {
        snapshot?.agents.flatMap(\.threads).filter { $0.id == id }.max { ($0.lastAt ?? .distantPast) < ($1.lastAt ?? .distantPast) }
    }

    func registerPush(_ token: String, environment: String) async {
        guard !demo, let client else { return }
        try? await client.registerPush(token: token, environment: environment)
    }

    func loadThread(_ id: String) async -> ThreadDetail? {
        if demo { return Samples.threadDetail(id) }
        guard let client else { return nil }
        return try? await client.thread(id)
    }

    /// Every finished plan read so far, newest first: the snapshot's latest, then the older pages.
    var planHistory: [Plan] {
        let latest = snapshot?.plans?.history ?? []
        let open = Set((snapshot?.plans?.open ?? []).map(\.id))
        var seen = Set(latest.map(\.id))
        let older = olderPlans.filter { !open.contains($0.id) && seen.insert($0.id).inserted }
        return (latest + older).sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// Whether older finished plans remain on the server.
    var hasOlderPlans: Bool { olderPlans.isEmpty ? snapshot?.plans?.next != nil : olderCursor != nil }

    func loadOlderPlans() async {
        guard let client, !loadingOlderPlans, let cursor = olderPlans.isEmpty ? snapshot?.plans?.next : olderCursor else { return }
        loadingOlderPlans = true
        defer { loadingOlderPlans = false }
        guard let page = try? await client.plans(history: true, before: cursor) else { return }
        olderPlans += page.plans
        olderCursor = page.next
    }

    func reasoningKey(_ plan: Plan, _ item: Plan.Item) -> String { "\(plan.id)/\(item.id)" }

    /// The steps linked to one checklist item, oldest first.
    func loadPlanReasoning(_ plan: Plan, _ item: Plan.Item) async {
        guard let client, let page = try? await client.planTask(plan, item: item.id) else { return }
        planReasoning[reasoningKey(plan, item)] = page.events.reversed().map(\.step)
    }

    func stepsFor(_ traceId: String) -> [Step] { steps[traceId] ?? traces[traceId]?.steps ?? [] }

    func avatarURL(_ agent: Agent) -> URL? { client?.avatarURL(agent.avatar) }

    func agentNames(_ account: Account) -> [String] {
        guard let snapshot else { return [] }
        return snapshot.agents.filter { account.agentIds.contains($0.id) || $0.accountIds.contains(account.id) }.map(\.name)
    }
}
