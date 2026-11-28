import AppKit
import CoraKit
import CryptoKit
import Foundation

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Creates the space on this Mac and keeps it running. Each step is real work the window shows while it happens:
/// the folder and its secrets, the agents' engines that are missing, the Linux VM and the agents' computer image, the LaunchAgent,
/// the panel's session, the menu bar's link.
@MainActor
final class LocalSpaceController: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case folder, engine, machine, computer, server, signIn, menuBar
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .folder: String(localized: "Prepare the space's folder")
            case .engine: String(localized: "Install the agents' engines")
            case .machine: String(localized: "Start the agents' Linux machine")
            case .computer: String(localized: "Build the agents' computer")
            case .server: String(localized: "Start Cora on this Mac")
            case .signIn: String(localized: "Sign in to the panel")
            case .menuBar: String(localized: "Connect the menu bar")
            }
        }

        var detail: String {
            switch self {
            case .folder: String(localized: "Settings and keys stay in Application Support")
            case .engine: String(localized: "Claude Code, Codex, Grok Build, DeepSeek Harness and Hermes, the ones this Mac lacks")
            case .machine: String(localized: "One virtual machine with Docker, Apple Virtualization")
            case .computer: String(localized: "Debian with desktop, browser and shell: one container per agent")
            case .server: String(localized: "On 127.0.0.1:4370, again at every login")
            case .signIn: String(localized: "This window opens the panel already signed in")
            case .menuBar: String(localized: "Agents, plans and threads at the top of the screen")
            }
        }
    }

    enum State: Equatable { case pending, running, done, failed(String) }

    enum Problem: LocalizedError {
        case notBundled, engines([String]), machine(String), computer(String), launch(Int32), timeout, signIn(String), pairing(String)
        var errorDescription: String? {
            switch self {
            case .notBundled: String(localized: "This build of Cora does not contain the server: download it again.")
            case .engines(let names): String(localized: "Not installed: \(names.joined(separator: ", ")). Check the connection and try again, or untick them above.")
            case .machine(let line): String(localized: "The Linux machine did not start: \(line)")
            case .computer(let line): String(localized: "The agents' computer was not built: \(line)")
            case .launch(let code): String(localized: "macOS did not start the space (launchctl \(code)).")
            case .timeout: String(localized: "Cora did not answer on 127.0.0.1:4370 within two minutes.")
            case .signIn(let message): String(localized: "The panel refused the sign-in: \(message)")
            case .pairing(let message): String(localized: "The menu bar could not connect: \(message)")
            }
        }
    }

    @Published private(set) var states: [Step: State] = [:]
    @Published private(set) var activity = ""
    @Published private(set) var running = false
    /// Every engine and where this Mac has it; nil until `lookForEngines` ran.
    @Published private(set) var engines: [EngineStatus]?
    /// The engines to install, by id: every missing one unless the person unticked it.
    @Published var chosen: Set<String> = []
    private var offered: Set<String> = []

    struct EngineStatus: Identifiable, Equatable {
        let engine: AgentEngine
        let found: String?
        var id: String { engine.id }
    }

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
    /// Colima, Lima and the Docker client the app brings, for the VM where the agents' computers run.
    static var tools: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cora-vm/bin") }
    static var colima: URL { tools.appendingPathComponent("colima") }
    static var docker: URL { tools.appendingPathComponent("docker") }
    static var box: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cora-server/box") }
    static var bundled: Bool {
        [node, colima, docker, tools.appendingPathComponent("limactl"), tools.appendingPathComponent("lima")].allSatisfy { FileManager.default.isExecutableFile(atPath: $0.path) } && FileManager.default.fileExists(atPath: main.path)
    }

    /// The folders the server will search: the space's own engines first, then the login shell's PATH.
    private nonisolated static func engineDirs(_ space: LocalSpace) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = [space.harnessBin.path]
        for dir in loginPath() + [home + "/.local/bin"] where !dirs.contains(dir) { dirs.append(dir) }
        return dirs
    }

    /// Looks for every engine where the server will look; a missing one is ticked the first time it shows up.
    func lookForEngines() async {
        let space = self.space
        let dirs = await Task.detached { Self.engineDirs(space) }.value
        let found = AgentEngine.all.map { EngineStatus(engine: $0, found: $0.locate(in: dirs)) }
        for status in found where status.found == nil && !offered.contains(status.id) {
            offered.insert(status.id)
            chosen.insert(status.id)
        }
        engines = found
    }

    func detail(_ step: Step) -> String {
        guard step == .engine, let engines else { return step.detail }
        let missing = engines.filter { $0.found == nil && chosen.contains($0.id) }.map(\.engine.product)
        if !missing.isEmpty { return String(localized: "To install: \(missing.joined(separator: ", "))") }
        let present = engines.filter { $0.found != nil }.map(\.engine.product)
        return present.isEmpty ? String(localized: "None chosen") : String(localized: "Already on this Mac: \(present.joined(separator: ", "))")
    }

    /// Installs the chosen engines that are still missing, one after the other; the ones that fail are named together.
    private func installEngines() async throws {
        await lookForEngines()
        var failed: [String] = []
        for status in engines ?? [] where status.found == nil && chosen.contains(status.id) {
            let engine = status.engine
            activity = String(localized: "Installing \(engine.product)…")
            let started = Date()
            let ok = await install(engine)
            note("engine \(engine.id) \(ok ? "installed" : "failed") in \(Int(Date().timeIntervalSince(started)))s")
            if !ok { failed.append(engine.product) }
        }
        await lookForEngines()
        let still = (engines ?? []).filter { $0.found == nil && chosen.contains($0.id) }.map(\.engine.product)
        for name in still where !failed.contains(name) { failed.append(name) }
        if !failed.isEmpty { throw Problem.engines(failed) }
    }

    private func install(_ engine: AgentEngine) async -> Bool {
        let home = NSHomeDirectory()
        let system = "/usr/bin:/bin:/usr/sbin:/sbin"
        switch engine.source {
        case .npm:
            guard let arguments = engine.npmArguments(prefix: space.harness) else { return false }
            try? FileManager.default.createDirectory(at: space.harness, withIntermediateDirectories: true)
            let code = try? await run(Self.node, [Self.npm.path] + arguments, label: engine.product,
                                      environment: ["PATH": "\(space.bin.path):\(system)", "HOME": home, "npm_config_update_notifier": "false"])
            return code == 0
        case .script(let address, let arguments):
            let file = space.runtime.appendingPathComponent("install-\(engine.id).sh")
            try? FileManager.default.createDirectory(at: space.runtime, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let fetched = try? await capture(URL(fileURLWithPath: "/usr/bin/curl"), ["-fsSL", "--retry", "3", "-o", file.path, address.absoluteString], environment: ["PATH": system]),
                  fetched.code == 0 else { return false }
            let login = await Task.detached { Self.loginPath() }.value
            let path = (login + [space.bin.path, system]).joined(separator: ":")
            let code = try? await run(URL(fileURLWithPath: "/bin/bash"), [file.path] + arguments, label: engine.product,
                                      environment: ["PATH": path, "HOME": home, "TERM": "dumb", "LANG": "en_US.UTF-8"])
            return code == 0
        }
    }

    /// Runs every step in order and stops at the first that fails; a second run skips what is already in place.
    @discardableResult
    func create() async -> Bool {
        guard !running else { return false }
        running = true
        defer { running = false }
        states = [:]
        activity = ""
        for step in Step.allCases {
            states[step] = .running
            let started = Date()
            note("\(step) started")
            do {
                try await perform(step)
                states[step] = .done
                activity = ""
                note("\(step) done in \(Int(Date().timeIntervalSince(started)))s")
            } catch {
                states[step] = .failed(error.localizedDescription)
                note("\(step) failed after \(Int(Date().timeIntervalSince(started)))s: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    /// Appends a timestamped line to the space's wizard.log.
    private func note(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        let file = space.wizardLog
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: file)
        }
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
            for (key, value) in LocalSpace.secrets() where values[key] == nil { values[key] = value }
            try space.writeEnv(values)
            activity = space.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .engine:
            try await installEngines()
        case .machine:
            try await startMachine()
        case .computer:
            try await buildComputer()
        case .server:
            try await start()
        case .signIn:
            _ = try await signIn()
        case .menuBar:
            onConnect(try await pairingLink())
        }
    }

    private var vmEnvironment: [String: String] { space.vmEnvironment(tools: Self.tools) }

    /// Boots the Colima VM (created the first time), registers it to boot again at login and writes its Docker socket for the server.
    func startMachine() async throws {
        for directory in [space.colimaHome, space.limaHome, space.dockerConfig] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if try await capture(Self.colima, ["status", LocalSpace.vmProfile], environment: vmEnvironment).code != 0 {
            let code = try await run(Self.colima, LocalSpace.vmStartArguments(), environment: vmEnvironment)
            guard code == 0 else { throw Problem.machine(lastVMLine() ?? "colima \(code)") }
        }
        let status = try await capture(Self.colima, ["status", LocalSpace.vmProfile, "--json"], environment: vmEnvironment)
        guard status.code == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(status.output.utf8)) as? [String: Any],
              let socket = json["docker_socket"] as? String, !socket.isEmpty else { throw Problem.machine(status.output.split(separator: "\n").last.map(String.init) ?? "colima status") }
        var values = space.readEnv()
        values["DOCKER_HOST"] = socket.hasPrefix("unix://") ? socket : "unix://\(socket)"
        try space.writeEnv(values)
        let docker = try await capture(Self.docker, ["info", "--format", "{{.ServerVersion}} {{.Architecture}}"], environment: dockerEnvironment)
        guard docker.code == 0 else { throw Problem.machine(docker.output.split(separator: "\n").last.map(String.init) ?? "docker") }
        activity = "Docker \(docker.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        let agent = try space.vmLaunchAgent(colima: Self.colima)
        let file = LocalSpace.vmLaunchAgentFile
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: file)) != agent { try agent.write(to: file, options: .atomic) }
    }

    private var dockerEnvironment: [String: String] {
        var values = vmEnvironment
        values["DOCKER_HOST"] = space.readEnv()["DOCKER_HOST"]
        return values
    }

    /// Builds `cora-box` from the Dockerfile the server brings, in the VM, for its own architecture; skipped when the image matches.
    func buildComputer() async throws {
        let label = Self.boxHash()
        let current = try await capture(Self.docker, ["image", "inspect", LocalSpace.boxImage, "--format", "{{index .Config.Labels \"cora.box\"}}"], environment: dockerEnvironment)
        if current.code == 0, current.output.trimmingCharacters(in: .whitespacesAndNewlines) == label { return }
        if await downloadComputer(label) { return }
        let code = try await run(Self.docker, ["build", "--label", "cora.box=\(label)", "-t", LocalSpace.boxImage, Self.box.path], environment: dockerEnvironment)
        guard code == 0 else { throw Problem.computer(activity.isEmpty ? "docker build \(code)" : activity) }
    }

    /// The image CI built from the same box/ for this Mac's VM, published as a release of the public cora-app repo:
    /// a download of about 1 GB instead of building 2.5 GB here. False when it is not there, and the VM builds it.
    func downloadComputer(_ label: String) async -> Bool {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let address = "https://github.com/digitaloracles/cora-app/releases/download/cora-box-\(label)/cora-box-\(arch).tar.gz"
        let file = space.runtime.appendingPathComponent("cora-box-\(label)-\(arch).tar.gz")
        try? FileManager.default.createDirectory(at: space.runtime, withIntermediateDirectories: true)
        let watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
                if size > 0 { self?.activity = String(localized: "Downloading the agents' computer: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))") }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer {
            watcher.cancel()
            try? FileManager.default.removeItem(at: file)
        }
        guard let fetched = try? await capture(URL(fileURLWithPath: "/usr/bin/curl"), ["-fsSL", "--retry", "3", "-o", file.path, address], environment: ["PATH": "/usr/bin:/bin"]),
              fetched.code == 0 else { return false }
        watcher.cancel()
        activity = String(localized: "Loading the agents' computer into the VM…")
        guard let loaded = try? await run(Self.docker, ["load", "-i", file.path], environment: dockerEnvironment), loaded == 0 else { return false }
        let current = try? await capture(Self.docker, ["image", "inspect", LocalSpace.boxImage, "--format", "{{index .Config.Labels \"cora.box\"}}"], environment: dockerEnvironment)
        return current?.code == 0 && current?.output.trimmingCharacters(in: .whitespacesAndNewlines) == label
    }

    /// The same label deploy/macos.sh gives the image: the first 16 hex digits of the SHA-256 of box/*, in name order.
    static func boxHash() -> String {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: box.path)) ?? []).sorted()
        var data = Data()
        for name in names { data.append((try? Data(contentsOf: box.appendingPathComponent(name))) ?? Data()) }
        return String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// The PATH of the person's login shell, where their CLIs are; the usual folders when the shell does not answer.
    nonisolated static func loginPath() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let usual = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.claude/local", home + "/.npm-global/bin", home + "/.bun/bin"]
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "printf '\\n__CORA_PATH__%s__CORA_PATH__\\n' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var found: [String] = []
        if (try? process.run()) != nil {
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate() }
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if let range = text.range(of: "__CORA_PATH__"), let end = text.range(of: "__CORA_PATH__", range: range.upperBound..<text.endIndex) {
                found = text[range.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
            }
        }
        return (found + usual).filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Starts the LaunchAgent when it is not loaded or points to another copy of the app, then waits for the panel.
    func start() async throws {
        linkNode()
        let userPath = await Task.detached { Self.loginPath() }.value
        let data = try space.launchAgent(node: Self.node, main: Self.main, tools: Self.tools, userPath: userPath)
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

    /// Brings the space back after a restart of the app: the VM first, then the server when it does not answer.
    func ensureRunning() async {
        guard exists, Self.bundled else { return }
        if (try? await capture(Self.colima, ["status", LocalSpace.vmProfile], environment: vmEnvironment).code) != 0 {
            _ = try? await run(Self.colima, ["start", LocalSpace.vmProfile, "--activate=false"], environment: vmEnvironment)
        }
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
        try await send("POST", path, body: body, cookies: cookies)
    }

    private func send(_ method: String, _ path: String, body: [String: Any], cookies: [HTTPCookie]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: LocalSpace.server.appendingPathComponent(path))
        request.httpMethod = method
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

    private func lastVMLine() -> String? { lastLogLine(space.limaHome.appendingPathComponent("colima-\(LocalSpace.vmProfile)/ha.stderr.log")) ?? (activity.isEmpty ? nil : activity) }

    private func lastLogLine(_ file: URL? = nil) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file ?? space.logFile) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 2048 ? size - 2048 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").last.map { String($0.prefix(160)) }
    }

    /// Runs a helper to the end and returns its output, without showing it.
    private func capture(_ executable: URL, _ arguments: [String], environment: [String: String]) async throws -> (code: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let buffer = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: (finished.terminationStatus, buffer.text))
            }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs a helper and shows its last line of output as it goes, after `label` when there is one.
    private func run(_ executable: URL, _ arguments: [String], label: String? = nil, environment: [String: String]) async throws -> Int32 {
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
            let text = String(((label.map { "\($0): " } ?? "") + line).prefix(160))
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
