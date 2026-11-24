import AppKit
import CoraKit
import Foundation

/// The connected space as the app shows it: the last snapshot, the live steps from the event stream, the connection state.
@MainActor
final class SpaceStore: ObservableObject {
    enum Phase: Equatable { case disconnected, waitingForPanel(String), connecting, ready, failed(String) }

    @Published private(set) var connection: Connection?
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var streamOnline = false
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var steps: [String: [Step]] = [:]
    @Published private(set) var traces: [String: TraceDetail] = [:]
    @Published var spaceInput = ""
    /// The subscriptions shown in the menu bar, chosen in the popover and kept on this Mac per space.
    @Published private(set) var pins: [String] = []
    /// The subscriptions opened to show every limit; the popover remembers them while the app runs.
    @Published var expanded: Set<String> = []
    /// A year of daily usage from the server; nil until read, or on servers without `/app/v1/usage`.
    @Published private(set) var history: UsageHistory?
    private var historyReadAt: Date?
    /// Finished plans older than the snapshot's, read page by page when the person asks.
    @Published private(set) var olderPlans: [Plan] = []
    @Published private(set) var olderCursor: String?
    @Published private(set) var loadingOlderPlans = false
    /// The reasoning linked to checklist items, by `planId/itemId`, read when an item is opened.
    @Published var planReasoning: [String: [Step]] = [:]

    /// Questions this device is answering now, so a second press waits for the first.
    @Published private(set) var answering: Set<String> = []
    /// The last answer sent from here, shown for a moment where the question was; and why the last press failed.
    @Published private(set) var lastAnswer: (agentName: String, answer: String)?
    @Published var choiceError: String?

    @Published var planToClose: Plan?
    @Published private(set) var closingPlans: Set<String> = []
    @Published private(set) var closeErrors: [String: String] = [:]

    func closePlan(_ plan: Plan) async {
        guard let client, closingPlans.insert(plan.id).inserted else { return }
        defer { closingPlans.remove(plan.id) }
        closeErrors[plan.id] = nil
        do {
            try await client.closePlan(plan)
        } catch ClientError.unauthorized(let message) {
            revoked(message)
            return
        } catch {
            closeErrors[plan.id] = error.localizedDescription
        }
        await refresh()
    }

    private(set) var client: CoraClient?
    private var streamTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pendingRefresh: Task<Void, Never>?
    private var keychainTask: Task<Void, Never>?
    private var keychainAttempt: UUID?
    private let maxSteps = 300
    /// Told when this Mac is paired with a space, and when the person disconnects it, so the list of spaces follows.
    var onConnected: (SpaceStore) -> Void = { _ in }
    var onDisconnected: (SpaceStore) -> Void = { _ in }

    /// One space of the list, read from the Keychain on `start`.
    init(connection: Connection) {
        self.connection = connection
        spaceInput = connection.host
    }

    init(preview: Snapshot? = nil, pins: [String] = [], history: UsageHistory? = nil) {
        self.pins = pins
        self.history = history
        if let preview {
            snapshot = preview
            phase = .ready
            connection = Connection(server: URL(string: preview.space.origin) ?? URL(string: "https://example.usecora.space")!, spaceName: preview.space.name, userName: preview.user.name, email: preview.user.email, deviceId: "preview")
        }
    }

    /// Reads the token off the main thread: a Keychain that does not answer (lid closed, locked session) must not freeze the app.
    func start() {
        guard let connection else { phase = .disconnected; return }
        if snapshot == nil { phase = .connecting }
        let attempt = UUID()
        keychainAttempt = attempt
        let slow = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled, self.keychainAttempt == attempt, self.client == nil else { return }
            self.phase = .failed(String(localized: "Waiting for the Keychain: unlock your Mac to read this space."))
        }
        keychainTask = Task { [weak self] in
            let token = await Task.detached(priority: .userInitiated) { Storage.token(for: connection) }.value
            slow.cancel()
            guard let self, self.keychainAttempt == attempt, self.connection?.server == connection.server else { return }
            guard let token else {
                // A Keychain that is not readable yet (wake, first unlock) keeps the pairing and tries again later.
                self.phase = .failed(String(localized: "The Keychain is locked: unlock your Mac to read this space."))
                Task { try? await Task.sleep(nanoseconds: 30_000_000_000); if self.client == nil, self.connection != nil, self.keychainAttempt == attempt { self.start() } }
                return
            }
            self.attach(self.connection ?? connection, token: token)
        }
    }

    /// `start`, then waits until the token is read and the space attached (the CLI renders right after).
    func startAndWait() async {
        start()
        await keychainTask?.value
    }

    private func attach(_ connection: Connection, token: String) {
        self.connection = connection
        pins = Pins.load(server: connection.server)
        client = CoraClient(server: connection.server, token: token)
        spaceInput = connection.host
        phase = snapshot == nil ? .connecting : .ready
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

    /// Sends the person to the panel of the space, signed in there, to authorize this Mac.
    func authorize() {
        guard let origin = Space.origin(spaceInput) else {
            phase = .failed(String(localized: "Write the address of your space, for example yourspace.usecora.space."))
            return
        }
        let state = Space.newState()
        Storage.rememberPendingState(state)
        phase = .waitingForPanel(origin.host ?? origin.absoluteString)
        NSWorkspace.shared.open(Space.authorizeURL(origin: origin, state: state))
    }

    /// A `cora://connect` link from the panel. One this Mac did not ask for is confirmed first.
    func handle(_ url: URL) {
        let link: ConnectLink
        do { link = try ConnectLink.parse(url) } catch {
            phase = .failed(String(localized: "This link does not come from a Cora panel."))
            return
        }
        let expected = Storage.takePendingState()
        if link.state == nil || link.state != expected {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = String(localized: "Connect this Mac to \(link.server.host ?? "")?")
            alert.informativeText = String(localized: "You can follow work, answer questions and close plans you manage.")
            alert.addButton(withTitle: String(localized: "Connect"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { await connect(link) }
    }

    func connect(_ link: ConnectLink) async {
        phase = .connecting
        do {
            let paired = try await CoraClient.exchange(link, deviceName: Host.current().localizedName ?? "Mac", platform: "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)")
            let connection = Connection(server: link.server, spaceName: link.server.host ?? "", userName: paired.user.name, email: paired.user.email, deviceId: paired.device.id)
            if let previous = self.connection, previous.server != connection.server { Storage.forget(previous) }
            try Storage.save(connection, token: paired.token)
            snapshot = nil
            steps = [:]; traces = [:]
            attach(connection, token: paired.token)
            onConnected(self)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        streamTask?.cancel(); pollTask?.cancel()
        if let client { try? await client.signOut() }
        if let connection { Storage.forget(connection) }
        client = nil; connection = nil; snapshot = nil; steps = [:]; traces = [:]; streamOnline = false
        history = nil; historyReadAt = nil; olderPlans = []; olderCursor = nil; planReasoning = [:]
        phase = .disconnected
        onDisconnected(self)
    }

    /// Stops reading the space, as when it leaves the list.
    func stop() {
        streamTask?.cancel(); pollTask?.cancel(); pendingRefresh?.cancel()
        client = nil; streamOnline = false
    }

    /// The space's name, as the switchers show it.
    var title: String { snapshot?.space.name ?? connection?.spaceName ?? connection?.host ?? String(localized: "New space") }

    func refresh() async {
        guard let client else { return }
        do {
            let fresh = try await client.snapshot()
            snapshot = fresh.hidingDismissed(server: client.server)
            await readHistory(client)
            refreshedAt = Date()
            phase = .ready
            if var connection, connection.spaceName != fresh.space.name || connection.userName != fresh.user.name {
                connection.spaceName = fresh.space.name; connection.userName = fresh.user.name
                self.connection = connection
                Storage.update(connection)
            }
        } catch ClientError.unauthorized(let message) {
            revoked(message)
        } catch {
            phase = snapshot == nil ? .failed(error.localizedDescription) : .ready
        }
    }

    /// The heatmap's year, read again every few minutes; until then (or on an older server) the snapshot's month.
    private func readHistory(_ client: CoraClient) async {
        if let historyReadAt, Date().timeIntervalSince(historyReadAt) < 300 { return }
        historyReadAt = Date()
        do { history = try await client.usage() }
        catch ClientError.http(404, _) { history = nil }
        catch {}
    }

    /// What the heatmaps draw.
    var usageHistory: UsageHistory? {
        guard let snapshot else { return nil }
        let month = UsageHistory(snapshot: snapshot)
        guard let history else { return month }
        // The snapshot is fresher: today's turns land there first.
        let recent = Set(month.usage.map(\.day))
        return UsageHistory(today: max(history.today, month.today), usage: history.usage.filter { !recent.contains($0.day) } + month.usage)
    }

    private func revoked(_ message: String) {
        streamTask?.cancel(); pollTask?.cancel()
        if let connection { Storage.forget(connection) }
        client = nil; streamOnline = false
        phase = .failed(message.isEmpty ? String(localized: "This Mac was disconnected from the space. Connect it again from the panel.") : message)
    }

    /// Presses one of the answers an agent offered: the agent hears it as the owner's word, and the question leaves the list.
    func answer(_ request: ChoiceRequest, index: Int) async {
        guard request.choices.indices.contains(index), !answering.contains(request.id) else { return }
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

    /// Sets a question aside: on a space that knows the route it leaves every app, otherwise only this Mac.
    func dismiss(_ request: ChoiceRequest) async {
        guard !answering.contains(request.id) else { return }
        snapshot?.requests.removeAll { $0.id == request.id }
        choiceError = nil
        guard let client else { return }
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
                    self?.revoked(message); return
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
        case "access-revoked": revoked("")
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

    func loadThread(_ id: String) async -> ThreadDetail? {
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

    func isPinned(_ account: Account) -> Bool { pins.contains(account.id) }

    func togglePin(_ account: Account) {
        if let index = pins.firstIndex(of: account.id) { pins.remove(at: index) } else { pins.append(account.id) }
        guard let server = connection?.server, connection?.deviceId != "preview" else { return }
        try? Pins.save(pins, server: server)
    }

    func toggleExpanded(_ account: Account) {
        if expanded.contains(account.id) { expanded.remove(account.id) } else { expanded.insert(account.id) }
    }

    func stepsFor(_ traceId: String) -> [Step] { steps[traceId] ?? traces[traceId]?.steps ?? [] }

    func avatarURL(_ agent: Agent) -> URL? { client?.avatarURL(agent.avatar) }
}
