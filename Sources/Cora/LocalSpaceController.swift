import AppKit
import CoraKit
import Foundation

/// Creates the space on this Mac and keeps it running. Each step is real work the window shows while it happens:
/// the folder and its secrets, the agents' engine from npm, the LaunchAgent, the panel's session, the menu bar's link.
@MainActor
final class LocalSpaceController: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case folder, engine, server, signIn, agent, menuBar
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .folder: String(localized: "Prepare the space's folder")
            case .engine: String(localized: "Install the agents' engine")
            case .server: String(localized: "Start Cora on this Mac")
            case .signIn: String(localized: "Sign in to the panel")
            case .agent: String(localized: "Create the first agent")
            case .menuBar: String(localized: "Connect the menu bar")
            }
        }

        var detail: String {
            switch self {
            case .folder: String(localized: "Settings and keys stay in Application Support")
            case .engine: String(localized: "DeepSeek Harness, from npm")
            case .server: String(localized: "On 127.0.0.1:4370, again at every login")
            case .signIn: String(localized: "This window opens the panel already signed in")
            case .agent: String(localized: "On DeepSeek V4.1 Flash, ready to chat")
            case .menuBar: String(localized: "Agents, plans and threads at the top of the screen")
            }
        }
    }

    enum State: Equatable { case pending, running, done, failed(String) }

    enum Problem: LocalizedError {
        case notBundled, engine, launch(Int32), timeout, signIn(String), agent(String), pairing(String), noKey
        var errorDescription: String? {
            switch self {
            case .notBundled: String(localized: "This build of Cora does not contain the server: download it again.")
            case .engine: String(localized: "The agents' engine did not install: check the connection and try again.")
            case .launch(let code): String(localized: "macOS did not start the space (launchctl \(code)).")
            case .timeout: String(localized: "Cora did not answer on 127.0.0.1:4370 within two minutes.")
            case .signIn(let message): String(localized: "The panel refused the sign-in: \(message)")
            case .agent(let message): String(localized: "The first agent was not created: \(message)")
            case .pairing(let message): String(localized: "The menu bar could not connect: \(message)")
            case .noKey: String(localized: "Paste a DeepSeek key: the agents of this space run on it.")
            }
        }
    }

    @Published private(set) var states: [Step: State] = [:]
    @Published private(set) var activity = ""
    @Published private(set) var running = false
    @Published var deepseekKey = ""
    @Published var agentName = "Lia"
    /// The first agent, once created: the window opens its chat.
    @Published private(set) var agentId: String? = UserDefaults.standard.string(forKey: LocalSpaceController.agentKey)
    static let agentKey = "localSpaceAgent"

    let space = LocalSpace()
    /// The `cora://connect` link of the new space, for the menu bar.
    var onConnect: (URL) -> Void = { _ in }
    private(set) var cookies: [HTTPCookie] = []
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    var exists: Bool { space.exists }
    var finished: Bool { Step.allCases.allSatisfy { states[$0] == .done } }
    var failure: String? {
        for step in Step.allCases { if case .failed(let message) = states[step] { return message } }
        return nil
    }
    func state(_ step: Step) -> State { states[step] ?? .pending }

    static var node: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cora-node") }
    static var main: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cora-server/src/main.js") }
    static var npm: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cora-npm/bin/npm-cli.js") }
    static var bundled: Bool { FileManager.default.isExecutableFile(atPath: node.path) && FileManager.default.fileExists(atPath: main.path) }

    /// Runs every step in order and stops at the first that fails; a second run skips what is already in place.
    @discardableResult
    func create() async -> Bool {
        guard !running else { return false }
        if !exists, deepseekKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            states = [.folder: .failed(Problem.noKey.localizedDescription)]
            return false
        }
        running = true
        defer { running = false }
        states = [:]
        activity = ""
        for step in Step.allCases {
            states[step] = .running
            do {
                try await perform(step)
                states[step] = .done
                activity = ""
            } catch {
                states[step] = .failed(error.localizedDescription)
                return false
            }
        }
        return true
    }

    private func perform(_ step: Step) async throws {
        switch step {
        case .folder:
            guard Self.bundled else { throw Problem.notBundled }
            let files = FileManager.default
            try files.createDirectory(at: space.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.createDirectory(at: space.bin, withIntermediateDirectories: true)
            linkNode()
            var values = space.readEnv()
            for (key, value) in LocalSpace.secrets(deepseekKey: deepseekKey) where values[key] == nil || key == "DEEPSEEK_API_KEY" { values[key] = value }
            try space.writeEnv(values)
            deepseekKey = ""
            activity = space.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .engine:
            if FileManager.default.isExecutableFile(atPath: space.dsh.path) { return }
            let code = try await run(Self.node, [Self.npm.path, "install", "--global", "--prefix", space.harness.path, "--no-audit", "--no-fund", "--loglevel", "http", "@deepseek-ai/dsh@latest"],
                                     environment: ["PATH": "\(space.bin.path):/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "npm_config_update_notifier": "false"])
            guard code == 0, FileManager.default.isExecutableFile(atPath: space.dsh.path) else { throw Problem.engine }
        case .server:
            try await start()
        case .signIn:
            _ = try await signIn()
        case .agent:
            if agentId == nil { try await createAgent() }
        case .menuBar:
            onConnect(try await pairingLink())
        }
    }

    /// Starts the LaunchAgent when it is not loaded or points to another copy of the app, then waits for the panel.
    func start() async throws {
        linkNode()
        let data = try space.launchAgent(node: Self.node, main: Self.main)
        let file = LocalSpace.launchAgentFile
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let domain = "gui/\(getuid())"
        if (try? Data(contentsOf: file)) != data || !loaded() {
            _ = launchctl(["bootout", "\(domain)/\(LocalSpace.label)"])
            try data.write(to: file, options: .atomic)
            var code: Int32 = 0
            for _ in 0..<10 {
                code = launchctl(["bootstrap", domain, file.path])
                if code == 0 || loaded() { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard code == 0 || loaded() else { throw Problem.launch(code) }
        }
        activity = String(localized: "Waiting for the panel…")
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if await answers() { activity = ""; return }
            if let line = lastLogLine() { activity = line }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        throw Problem.timeout
    }

    /// Brings the space back after a restart of the app: nothing to do when it already answers.
    func ensureRunning() async {
        guard exists, Self.bundled else { return }
        if await answers() { return }
        try? await start()
    }

    func answers() async -> Bool {
        var request = URLRequest(url: LocalSpace.server.appendingPathComponent("api/me"))
        request.timeoutInterval = 2
        request.setValue("1", forHTTPHeaderField: "X-Cora")
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Signs in with the space's own password and keeps the session cookie for the window.
    func signIn() async throws -> [HTTPCookie] {
        let password = space.readEnv()["CORA_ADMIN_PASSWORD"] ?? ""
        let (data, response) = try await post("api/login", body: ["password": password], cookies: [])
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw Problem.signIn(Self.message(data, response)) }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { if let key = $1.key as? String, let value = $1.value as? String { $0[key] = value } }
        let found = HTTPCookie.cookies(withResponseHeaderFields: headers, for: LocalSpace.server)
        guard !found.isEmpty else { throw Problem.signIn(String(localized: "no session")) }
        cookies = found
        return found
    }

    /// The space's first agent, made as the panel's New agent page makes one: DeepSeek V4.1 Flash on this space's key.
    func createAgent() async throws {
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = ["name": name.isEmpty ? "Lia" : name, "color": "#f2a93b", "enabled": true, "model": "deepseek/deepseek-flash", "tools": false]
        let (data, response) = try await post("api/agents", body: body, cookies: cookies)
        guard (response as? HTTPURLResponse)?.statusCode == 201,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = json["id"] as? String else { throw Problem.agent(Self.message(data, response)) }
        agentId = id
        UserDefaults.standard.set(id, forKey: Self.agentKey)
        activity = name
    }

    /// A pairing the panel issues to the signed-in owner, as the button in the panel does.
    func pairingLink() async throws -> URL {
        if cookies.isEmpty { _ = try await signIn() }
        let state = UUID().uuidString.lowercased()
        Storage.rememberPendingState(state)
        let (data, response) = try await post("api/app/pairings", body: ["state": state], cookies: cookies)
        guard (response as? HTTPURLResponse)?.statusCode == 201,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["link"] as? String, let link = URL(string: text) else { throw Problem.pairing(Self.message(data, response)) }
        return link
    }

    private func post(_ path: String, body: [String: Any], cookies: [HTTPCookie]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: LocalSpace.server.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("1", forHTTPHeaderField: "X-Cora")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await session.data(for: request)
    }

    private static func message(_ data: Data, _ response: URLResponse) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = json["error"] as? String { return error }
        return "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
    }

    /// `node` on the space's PATH is the app's own: npm scripts and the harness find it there.
    private func linkNode() {
        let link = space.bin.appendingPathComponent("node")
        try? FileManager.default.createDirectory(at: space.bin, withIntermediateDirectories: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == Self.node.path { return }
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: Self.node)
    }

    private func loaded() -> Bool { launchctl(["print", "gui/\(getuid())/\(LocalSpace.label)"]) == 0 }

    private func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func lastLogLine() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: space.logFile) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 2048 ? size - 2048 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").last.map { String($0.prefix(160)) }
    }

    /// Runs a helper and shows its last line of output as it goes.
    private func run(_ executable: URL, _ arguments: [String], environment: [String: String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = space.root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            guard let line = chunk.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
            let text = String(line.prefix(160))
            Task { @MainActor in self?.activity = text }
        }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: finished.terminationStatus)
            }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
