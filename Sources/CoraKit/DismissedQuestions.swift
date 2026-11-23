import Foundation

/// Questions the person set aside on this device, per space: a space older than the dismiss route cannot close
/// them for everyone, so this device keeps hiding them until they close on the server or a week goes by.
public enum DismissedQuestions {
    static var file: URL { Storage.home.appendingPathComponent("dismissed-questions.json") }
    static let keep: TimeInterval = 7 * 86_400

    static func all() -> [String: [String: Date]] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: [String: Date]].self, from: data)) ?? [:]
    }

    public static func load(server: URL, now: Date = Date()) -> Set<String> {
        Set((all()[server.absoluteString] ?? [:]).filter { now.timeIntervalSince($0.value) < keep }.keys)
    }

    public static func add(_ id: String, server: URL, now: Date = Date()) {
        var everything = all()
        var ids = (everything[server.absoluteString] ?? [:]).filter { now.timeIntervalSince($0.value) < keep }
        ids[id] = now
        everything[server.absoluteString] = ids
        try? FileManager.default.createDirectory(at: Storage.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(everything).write(to: file, options: .atomic)
    }
}

extension Snapshot {
    /// The snapshot without the questions set aside on this device.
    public func hidingDismissed(server: URL) -> Snapshot {
        let hidden = DismissedQuestions.load(server: server)
        guard !hidden.isEmpty else { return self }
        var copy = self
        copy.requests.removeAll { hidden.contains($0.id) }
        return copy
    }
}
