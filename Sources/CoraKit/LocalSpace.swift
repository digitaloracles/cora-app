import Foundation

#if os(macOS)

/// The space that runs on this Mac: its folder, the server's settings and the LaunchAgent that keeps it running.
/// The app brings Node and the Cora server inside its bundle; the space's data stays in its own folder.
public struct LocalSpace: Sendable {
    public static let port = 4370
    public static let label = "space.usecora.local"
    public static let server = URL(string: "http://127.0.0.1:\(port)")!

    public static let vmLabel = "space.usecora.vm"
    /// The Colima profile: one Linux VM where every agent's computer runs as a `cora-box` container.
    public static let vmProfile = "cora"
    public static let boxImage = "cora-box:latest"

    public let root: URL
    /// Colima, Lima and Docker keep their state here: a short path, because their sockets live in it.
    public let runtime: URL

    public init(root: URL? = nil, runtime: URL? = nil) {
        self.root = root ?? Storage.home.appendingPathComponent("Local", isDirectory: true)
        self.runtime = runtime ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cora-local", isDirectory: true)
    }

    public var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    public var harness: URL { root.appendingPathComponent("harness", isDirectory: true) }
    public var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public var envFile: URL { root.appendingPathComponent("env") }
    public var logFile: URL { root.appendingPathComponent("cora.log") }
    public var dsh: URL { harness.appendingPathComponent("bin/dsh") }
    public var vmLogFile: URL { root.appendingPathComponent("vm.log") }
    public var colimaHome: URL { runtime.appendingPathComponent("colima", isDirectory: true) }
    public var limaHome: URL { runtime.appendingPathComponent("lima", isDirectory: true) }
    public var dockerConfig: URL { runtime.appendingPathComponent("docker", isDirectory: true) }

    public static var vmLaunchAgentFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(vmLabel).plist")
    }

    /// What Colima, Lima and the Docker client read: their own homes, never the user's ~/.colima or ~/.docker.
    public func vmEnvironment(tools: URL) -> [String: String] {
        [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "COLIMA_HOME": colimaHome.path,
            "LIMA_HOME": limaHome.path,
            "DOCKER_CONFIG": dockerConfig.path,
            "PATH": [tools.path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
        ]
    }

    /// The VM's size: half the Mac's cores (2 to 4) and a quarter of its memory (4 to 8 GB), so the Mac stays usable.
    public static func vmSize(cores: Int = ProcessInfo.processInfo.processorCount, memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> (cpus: Int, memoryGB: Int, diskGB: Int) {
        let gigabytes = Int(memory / 1_073_741_824)
        return (min(4, max(2, cores / 2)), min(8, max(4, gigabytes / 4)), 60)
    }

    /// `colima start`: the first time it creates the VM with VZ, Apple's own virtualization; afterwards it only boots it.
    public static func vmStartArguments(cores: Int = ProcessInfo.processInfo.processorCount, memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [String] {
        let size = vmSize(cores: cores, memory: memory)
        return ["start", vmProfile, "--vm-type", "vz", "--runtime", "docker", "--cpu", String(size.cpus), "--memory", String(size.memoryGB), "--disk", String(size.diskGB), "--activate=false"]
    }

    /// At every login: boot the VM again, then exit (Lima's own agent keeps it running).
    public func vmLaunchAgent(colima: URL) throws -> Data {
        let plist: [String: Any] = [
            "Label": LocalSpace.vmLabel,
            "ProgramArguments": [colima.path, "start", LocalSpace.vmProfile, "--activate=false"],
            "EnvironmentVariables": vmEnvironment(tools: colima.deletingLastPathComponent()),
            "WorkingDirectory": root.path,
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "StandardOutPath": vmLogFile.path,
            "StandardErrorPath": vmLogFile.path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// Created once the settings exist; the server may still be starting.
    public var exists: Bool { FileManager.default.fileExists(atPath: envFile.path) }

    public static var launchAgentFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// A random secret of `bytes` bytes, hex encoded.
    public static func secret(bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// The settings only this Mac knows: the panel password and the session key. Models and their keys are set per agent in the panel.
    public static func secrets() -> [String: String] {
        ["CORA_ADMIN_PASSWORD": secret(bytes: 16), "CORA_SESSION_KEY": secret(bytes: 32)]
    }

    /// `NAME='value'` lines a POSIX shell reads with `set -a; . file`.
    public static func envText(_ values: [String: String]) -> String {
        values.keys.sorted().map { key in
            "\(key)='\(values[key]!.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: "\n") + "\n"
    }

    public static func parseEnv(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            var value = String(line[line.index(after: equals)...])
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
            }
            values[key] = value
        }
        return values
    }

    public func readEnv() -> [String: String] {
        (try? String(contentsOf: envFile, encoding: .utf8)).map(LocalSpace.parseEnv) ?? [:]
    }

    public func writeEnv(_ values: [String: String]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(LocalSpace.envText(values).utf8).write(to: envFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
    }

    /// What the server reads besides the secrets: where it lives, where it listens, where the agents' harness is.
    /// The server's PATH: the app's own Node, the harness and the VM tools first, then the person's login shell PATH
    /// (Homebrew, ~/.local/bin and the like, where Claude Code, Codex and the other CLIs already are), then the system.
    public func serverPath(tools: URL? = nil, userPath: [String] = []) -> String {
        let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var dirs = [bin.path, harness.appendingPathComponent("bin").path] + (tools.map { [$0.path] } ?? [])
        for dir in userPath + system where dir.hasPrefix("/") && !dirs.contains(dir) { dirs.append(dir) }
        return dirs.joined(separator: ":")
    }

    public func serverEnvironment(tools: URL? = nil, userPath: [String] = []) -> [String: String] {
        var values = [
            "CORA_HOME": home.path,
            "CORA_LISTEN_HOST": "127.0.0.1",
            "PORT": String(LocalSpace.port),
            "CORA_DSH_BIN": dsh.path,
            "CORA_INSECURE_COOKIES": "1",
            "PATH": serverPath(tools: tools, userPath: userPath),
        ]
        // The agents' computers: containers in the VM, reached with the app's Docker client on the VM's socket.
        if let tools {
            values["CORA_DOCKER"] = tools.appendingPathComponent("docker").path
            values["CORA_BOX_IMAGE"] = LocalSpace.boxImage
            values["DOCKER_CONFIG"] = dockerConfig.path
            values["COLIMA_HOME"] = colimaHome.path
            values["LIMA_HOME"] = limaHome.path
        }
        return values
    }

    /// The LaunchAgent: started at login, restarted if it stops, logs in the space's folder.
    public func launchAgent(node: URL, main: URL, tools: URL? = nil, userPath: [String] = []) throws -> Data {
        let plist: [String: Any] = [
            "Label": LocalSpace.label,
            "ProgramArguments": ["/bin/sh", "-c", "set -a; . \"$0\"; set +a; exec \"$1\" --disable-warning=ExperimentalWarning \"$2\"", envFile.path, node.path, main.path],
            "EnvironmentVariables": serverEnvironment(tools: tools, userPath: userPath),
            "WorkingDirectory": root.path,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}
#endif
