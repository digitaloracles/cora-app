import Foundation

/// The space that runs on this Mac: its folder, the server's settings and the LaunchAgent that keeps it running.
/// The app brings Node and the Cora server inside its bundle; the space's data stays in its own folder.
public struct LocalSpace: Sendable {
    public static let port = 4370
    public static let label = "space.usecora.local"
    public static let server = URL(string: "http://127.0.0.1:\(port)")!

    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? Storage.home.appendingPathComponent("Local", isDirectory: true)
    }

    public var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    public var harness: URL { root.appendingPathComponent("harness", isDirectory: true) }
    public var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public var envFile: URL { root.appendingPathComponent("env") }
    public var logFile: URL { root.appendingPathComponent("cora.log") }
    public var dsh: URL { harness.appendingPathComponent("bin/dsh") }

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

    /// The settings only this Mac knows: the panel password, the session key and the model's key.
    public static func secrets(deepseekKey: String) -> [String: String] {
        var values = ["CORA_ADMIN_PASSWORD": secret(bytes: 16), "CORA_SESSION_KEY": secret(bytes: 32)]
        let key = deepseekKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { values["DEEPSEEK_API_KEY"] = key }
        return values
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
    public func serverEnvironment() -> [String: String] {
        [
            "CORA_HOME": home.path,
            "CORA_LISTEN_HOST": "127.0.0.1",
            "PORT": String(LocalSpace.port),
            "CORA_DSH_BIN": dsh.path,
            "CORA_INSECURE_COOKIES": "1",
            "PATH": [bin.path, harness.appendingPathComponent("bin").path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":"),
        ]
    }

    /// The LaunchAgent: started at login, restarted if it stops, logs in the space's folder.
    public func launchAgent(node: URL, main: URL) throws -> Data {
        let plist: [String: Any] = [
            "Label": LocalSpace.label,
            "ProgramArguments": ["/bin/sh", "-c", "set -a; . \"$0\"; set +a; exec \"$1\" --disable-warning=ExperimentalWarning \"$2\"", envFile.path, node.path, main.path],
            "EnvironmentVariables": serverEnvironment(),
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
