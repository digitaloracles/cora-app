import CoraKit
import Foundation

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
    init(demo snapshot: Snapshot, steps: [String: [Step]]) {
        let connection = Connection(server: URL(string: snapshot.space.origin)!, spaceName: snapshot.space.name, userName: snapshot.user.name, email: snapshot.user.email, deviceId: "demo")
        self.connection = connection
        id = connection.server
        self.snapshot = snapshot
        self.steps = steps
        phase = .ready
        streamOnline = true
        refreshedAt = Date().addingTimeInterval(-40)
        demo = true
    }

    init(connection: Connection, token: String) {
        self.connection = connection
        self.id = connection.server
        client = CoraClient(server: connection.server, token: token)
    }

    var title: String { snapshot?.space.name ?? connection.spaceName }

    /// Starts reading: a snapshot now and every minute, and the live stream while the app is in front.
    func start() {
        if demo { return }
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
    }

    func refresh() async {
        guard let client else { return }
        do {
            let fresh = try await client.snapshot()
            snapshot = fresh
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
        case "subscription-usage", "agents", "agent-owners": scheduleRefresh()
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

    func stepsFor(_ traceId: String) -> [Step] { steps[traceId] ?? traces[traceId]?.steps ?? [] }

    func avatarURL(_ agent: Agent) -> URL? { client?.avatarURL(agent.avatar) }

    func agentNames(_ account: Account) -> [String] {
        guard let snapshot else { return [] }
        return snapshot.agents.filter { account.agentIds.contains($0.id) || $0.accountIds.contains(account.id) }.map(\.name)
    }
}
