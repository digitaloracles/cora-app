import Foundation

/// The subscriptions a person keeps in the menu bar, per space, saved on this Mac.
public enum Pins {
    static var file: URL { Storage.home.appendingPathComponent("pins.json") }

    static func all() -> [String: [String]] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    public static func load(server: URL) -> [String] { all()[server.absoluteString] ?? [] }

    public static func save(_ ids: [String], server: URL) throws {
        var everything = all()
        everything[server.absoluteString] = ids.isEmpty ? nil : ids
        try FileManager.default.createDirectory(at: Storage.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(everything).write(to: file, options: .atomic)
    }
}

/// One pinned subscription as the menu bar shows it: `Claude 29%`.
public struct PinnedQuota: Equatable, Sendable {
    public var accountId: String
    public var title: String
    public var window: QuotaWindow?

    public var text: String { window.map { "\(title) \(Format.percent($0.remainingPercent))" } ?? "\(title) –" }
}

extension Snapshot {
    /// The pinned subscriptions in the order of the space, named by provider, with the label when two share one.
    public func pinned(_ ids: [String]) -> [PinnedQuota] {
        let chosen = accounts.filter { ids.contains($0.id) }
        let providers = Dictionary(grouping: chosen, by: \.provider)
        return chosen.map { account in
            let shared = (providers[account.provider]?.count ?? 0) > 1
            let detail = account.label.isEmpty ? account.email.split(separator: "@").first.map(String.init) ?? account.id : account.label
            let title = shared && detail != Providers.name(account.provider) ? "\(Providers.name(account.provider)) · \(detail)" : Providers.name(account.provider)
            return PinnedQuota(accountId: account.id, title: title, window: account.tightestWindow)
        }
    }
}
