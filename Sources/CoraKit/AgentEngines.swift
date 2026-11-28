import Foundation

#if os(macOS)

/// The CLIs Cora runs agents with, as the server knows them (`src/harness-updates.js`): what each one's command is
/// and where it is installed from when this Mac does not have it yet.
public struct AgentEngine: Sendable, Identifiable, Equatable {
    public enum Source: Sendable, Equatable {
        /// An npm package, installed into the space's own folder with the app's Node.
        case npm(String)
        /// The vendor's own installer script, run with these arguments; it puts the command in the person's PATH.
        case script(URL, [String])
    }

    /// The harness id in Cora: `claude`, `codex`, `grok`, `deepseek`, `hermes`.
    public let id: String
    public let product: String
    public let command: String
    public let source: Source

    public static let all: [AgentEngine] = [
        AgentEngine(id: "claude", product: "Claude Code", command: "claude", source: .npm("@anthropic-ai/claude-code")),
        AgentEngine(id: "codex", product: "Codex", command: "codex", source: .npm("@openai/codex")),
        AgentEngine(id: "grok", product: "Grok Build", command: "grok", source: .npm("@xai-official/grok")),
        AgentEngine(id: "deepseek", product: "DeepSeek Harness", command: "dsh", source: .npm("@deepseek-ai/dsh")),
        AgentEngine(id: "hermes", product: "Hermes", command: "hermes",
                    source: .script(URL(string: "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh")!,
                                    ["--non-interactive", "--skip-browser", "--skip-computer-use"])),
    ]

    /// The npm arguments that install it into `prefix` (its command lands in `prefix/bin`), nil for a script.
    public func npmArguments(prefix: URL) -> [String]? {
        guard case .npm(let package) = source else { return nil }
        return ["install", "--global", "--prefix", prefix.path, "--no-audit", "--no-fund", "--loglevel", "http", "\(package)@latest"]
    }

    /// The first executable `command` in `dirs`, in their order, as the server's PATH lookup finds it.
    public func locate(in dirs: [String], files: FileManager = .default) -> String? {
        for dir in dirs where dir.hasPrefix("/") {
            let path = URL(fileURLWithPath: dir).appendingPathComponent(command).path
            var folder: ObjCBool = false
            if files.fileExists(atPath: path, isDirectory: &folder), !folder.boolValue, files.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

#endif
