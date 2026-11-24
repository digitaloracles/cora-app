import Foundation

public enum ClientError: Error, LocalizedError, Equatable {
    case unauthorized(String)
    case http(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let message): return message.isEmpty ? "Access revoked or expired." : message
        case .http(let status, let message): return message.isEmpty ? "The server answered \(status)." : message
        case .invalidResponse: return "The server sent an unexpected answer."
        }
    }
}

public struct Paired: Decodable, Sendable {
    public var token: String
    public var server: String
    public var user: Snapshot.User
    public var device: Device

    public struct Device: Decodable, Sendable { public var id: String; public var name: String }
}

/// Reads one Cora space with a device token. Every call is read-only except signing this device out, its push token answering an agent's question and closing an authorized plan.
public struct CoraClient: Sendable {
    public let server: URL
    let token: String
    let session: URLSession

    public init(server: URL, token: String, session: URLSession = .shared) {
        self.server = server; self.token = token; self.session = session
    }

    public static func exchange(_ link: ConnectLink, deviceName: String, platform: String, session: URLSession = .shared) async throws -> Paired {
        var request = URLRequest(url: link.server.appendingPathComponent("app/v1/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Cora")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": link.code, "name": deviceName, "platform": platform])
        let (data, response) = try await session.data(for: request)
        try check(data, response)
        return try JSONDecoder().decode(Paired.self, from: data)
    }

    func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: server.absoluteString + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-Cora")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request(path))
        try Self.check(data, response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func snapshot() async throws -> Snapshot { try await get("/app/v1/snapshot", as: Snapshot.self) }
    /// A year of daily usage; servers released before the heatmap answer 404.
    public func usage(days: Int = 365) async throws -> UsageHistory { try await get("/app/v1/usage?days=\(days)", as: UsageHistory.self) }
    public func trace(_ id: String) async throws -> TraceDetail { try await get("/app/v1/traces/\(id)", as: TraceDetail.self) }
    public func thread(_ id: String) async throws -> ThreadDetail {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.:"))) ?? id
        return try await get("/app/v1/threads/\(escaped)", as: ThreadDetail.self)
    }

    /// Plans across every thread: `open` ones, or the `history` of finished ones newest first, older pages with `before`.
    public func plans(history: Bool, before: String? = nil, limit: Int = 50) async throws -> PlanPage {
        var path = "/app/v1/plans?status=\(history ? "history" : "open")&limit=\(limit)"
        if let before, let escaped = before.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { path += "&before=\(escaped)" }
        return try await get(path, as: PlanPage.self)
    }

    public func closePlan(_ plan: Plan) async throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:"))
        guard plan.allowsOwnerClose,
              let thread = plan.channelId.addingPercentEncoding(withAllowedCharacters: allowed),
              let id = plan.id.addingPercentEncoding(withAllowedCharacters: allowed)
        else { throw ClientError.invalidResponse }
        var call = request("/app/v1/threads/\(thread)/plans/\(id)/close", method: "POST")
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.httpBody = try JSONEncoder().encode(["revision": plan.revision])
        let (data, response) = try await session.data(for: call)
        try Self.check(data, response)
    }

    /// The reasoning an agent linked to one checklist item.
    public func planTask(_ plan: Plan, item: String) async throws -> PlanTaskReasoning {
        let escaped = plan.channelId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.:"))) ?? plan.channelId
        return try await get("/app/v1/threads/\(escaped)/plans/\(plan.id)/tasks/\(item)", as: PlanTaskReasoning.self)
    }

    /// Presses one of the answers an agent offered: it reaches the agent as the owner's word, and the chat shows it in place of the buttons.
    public func answer(_ request: ChoiceRequest, index: Int) async throws -> ChoiceAnswer {
        var request = self.request("/app/v1/choices/\(request.id)", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["index": index])
        let (data, response) = try await session.data(for: request)
        try Self.check(data, response)
        return try JSONDecoder().decode(ChoiceAnswer.self, from: data)
    }

    /// Sets a question aside: it leaves every app and the agent hears nothing. False when the space is older than
    /// this route and the question can only be hidden on this device; a question already closed counts as set aside.
    @discardableResult
    public func dismiss(_ request: ChoiceRequest) async throws -> Bool {
        var call = self.request("/app/v1/choices/\(request.id)/dismiss", method: "POST")
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
        call.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: call)
        if let http = response as? HTTPURLResponse, [404, 405, 409].contains(http.statusCode) { return http.statusCode == 409 }
        try Self.check(data, response)
        return true
    }

    public func signOut() async throws {
        let (data, response) = try await session.data(for: request("/app/v1/session", method: "DELETE"))
        try Self.check(data, response)
    }

    /// Hands the space this device's APNs token, so its notifications reach the phone; the only other write besides signing out.
    public func registerPush(token: String, environment: String) async throws {
        var request = request("/app/v1/push", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "environment": environment])
        let (data, response) = try await session.data(for: request)
        try Self.check(data, response)
    }

    public func avatarURL(_ path: String) -> URL? { path.isEmpty ? nil : URL(string: server.absoluteString + path) }

    /// The space's live events: every reasoning step of this person's agents, as it happens.
    public func events() -> AsyncThrowingStream<ServerEvent, Error> {
        var request = request("/app/v1/events")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 24 * 3600
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
                    if http.statusCode == 401 { throw ClientError.unauthorized("") }
                    guard http.statusCode == 200 else { throw ClientError.http(http.statusCode, "") }
                    var parser = EventParser()
                    var line = Data()
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if let payload = parser.feed(String(decoding: line, as: UTF8.self)), let event = ServerEvent.decode(payload) {
                                continuation.yield(event)
                            }
                            line.removeAll(keepingCapacity: true)
                        } else if byte != UInt8(ascii: "\r") {
                            line.append(byte)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        if (200..<300).contains(http.statusCode) { return }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? ""
        if http.statusCode == 401 { throw ClientError.unauthorized(message) }
        throw ClientError.http(http.statusCode, message)
    }
}

/// Server-sent events: `data:` lines up to a blank line make one event.
public struct EventParser: Sendable {
    var data: [String] = []
    public init() {}

    public mutating func feed(_ line: String) -> String? {
        if line.isEmpty {
            defer { data.removeAll() }
            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.hasPrefix(" ") { value = value.dropFirst() }
            data.append(String(value))
        }
        return nil
    }
}

public struct ServerEvent: Decodable, Sendable {
    public var type: String
    public var event: String
    public var traceId: String
    public var agentId: String
    public var channelId: String
    public var step: Step?
    public var trace: TraceSummary?
    /// On `plan` events: which plan changed and its new status.
    public var planId: String
    public var status: String
    public var done: Int
    public var total: Int
    /// On `choice` events: the question asked or answered (`status` open or answered).
    public var choiceId: String

    public struct TraceSummary: Decodable, Sendable, Hashable {
        public var id: String
        public var agentId: String
        public var channelId: String
        public var status: String
        public var tokensIn: Int
        public var tokensOut: Int
        public var output: String

        enum CodingKeys: String, CodingKey { case id, agentId, channelId, status, tokensIn, tokensOut, output }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            agentId = c.text(.agentId); channelId = c.text(.channelId); status = c.text(.status)
            tokensIn = c.number(.tokensIn); tokensOut = c.number(.tokensOut); output = c.text(.output)
        }
    }

    enum CodingKeys: String, CodingKey { case type, event, traceId, agentId, channelId, step, trace, planId, status, done, total, choiceId = "id" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.text(.type); event = c.text(.event); traceId = c.text(.traceId); agentId = c.text(.agentId); channelId = c.text(.channelId)
        step = try? c.decodeIfPresent(Step.self, forKey: .step)
        trace = try? c.decodeIfPresent(TraceSummary.self, forKey: .trace)
        planId = c.text(.planId); status = c.text(.status); done = c.number(.done); total = c.number(.total)
        choiceId = c.text(.choiceId)
    }

    public static func decode(_ text: String) -> ServerEvent? { try? JSONDecoder().decode(ServerEvent.self, from: Data(text.utf8)) }
}
