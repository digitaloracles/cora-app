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
    public var provider: String
    public var title: String
    public var window: QuotaWindow?
    public var balance: Balance? = nil

    /// The account-wide windows, shortest first, as the menu bar stacks them: `5h 64%` above `7d 80%`.
    public var windows: [QuotaWindow] = []

    public var text: String { windows.count > 1 ? "\(title) " + windows.map { "\($0.tag()) \(Format.percent($0.remainingPercent))" }.joined(separator: " · ") : "\(title) \(value)" }
    /// What sits next to the provider's icon: `29%`, the balance of a pay-as-you-go account (`$14.90`), or `–`.
    public var value: String { window.map { Format.percent($0.remainingPercent) } ?? balance?.text ?? "–" }
    /// Red when the window is near its limit or the balance has run out.
    public var level: QuotaWindow.Level? { window?.level ?? (balance?.isEmpty == true ? .critical : nil) }
}

extension Snapshot {
    /// The pinned subscriptions in the order of the space, named by provider, with the label when two share one.
    public func pinned(_ ids: [String]) -> [PinnedQuota] {
        let chosen = accounts.filter { ids.contains($0.id) }
        return chosen.map { account in
            PinnedQuota(accountId: account.id, provider: account.provider, title: title(of: account, among: chosen), window: account.tightestWindow, balance: account.tightestWindow == nil ? account.balance : nil, windows: account.mainWindows)
        }
    }

    /// The provider's name, with the label or the mailbox when another subscription in `list` has the same provider.
    public func title(of account: Account, among list: [Account]? = nil) -> String {
        let shared = (list ?? accounts).filter { $0.provider == account.provider }.count > 1
        let name = Providers.name(account.provider)
        let named = !account.label.isEmpty && account.label != name
        let detail = named ? account.label : account.email.split(separator: "@").first.map(String.init) ?? account.id
        return shared && detail != name ? "\(name) · \(detail)" : name
    }
}
