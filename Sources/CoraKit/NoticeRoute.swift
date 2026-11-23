import Foundation

/// What a tapped notification opens: a plan, a conversation, an agent, the subscriptions, or a panel page the app has no screen for.
public enum NoticeRoute: Equatable, Sendable {
    case plan(String)
    case thread(String)
    case agent(String)
    case subscriptions
    case panel(String)
}

/// A tapped notification: the space that sent it, when it says so, and where it leads.
public struct Notice: Equatable, Sendable {
    public let space: URL?
    public let route: NoticeRoute

    public init(space: URL?, route: NoticeRoute) {
        self.space = space
        self.route = route
    }

    /// Reads the payload a space sends with a notification. Older spaces send only the panel link, so the plan, thread or agent is read from it too.
    public init?(payload info: [AnyHashable: Any]) {
        func text(_ key: String) -> String? { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let url = text("url")
        let parts = Self.hashParts(url)
        let space = text("space").flatMap(URL.init(string:))
        if let plan = text("planId") {
            self.init(space: space, route: .plan(plan))
        } else if let channel = text("channelId") ?? Self.threadId(parts) {
            self.init(space: space, route: Self.isPanelRoom(channel) ? Self.roomRoute(channel, url: url) : .thread(channel))
        } else if let agent = text("agentId") ?? (parts.first == "agent" && parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil) {
            self.init(space: space, route: .agent(agent))
        } else if text("kind") == "quota" {
            self.init(space: space, route: .subscriptions)
        } else if let url {
            self.init(space: space, route: .panel(url))
        } else {
            return nil
        }
    }

    /// The address of a panel page on the space's own origin.
    public static func panelURL(_ path: String, origin: URL) -> URL? {
        if let absolute = URL(string: path), absolute.scheme == "https" || absolute.scheme == "http" { return absolute }
        return URL(string: path, relativeTo: origin)?.absoluteURL
    }

    /// Whether this notice belongs to the space at `server`: a notice that does not name its space belongs to any.
    public func belongs(to server: URL) -> Bool {
        guard let host = space?.host?.lowercased() else { return true }
        return server.host?.lowercased() == host
    }

    static func hashParts(_ url: String?) -> [String] {
        guard let url, let hash = url.split(separator: "#", maxSplits: 1).dropFirst().first else { return [] }
        return hash.split(separator: "/", omittingEmptySubsequences: false).dropFirst(hash.hasPrefix("/") ? 1 : 0).map { String($0).removingPercentEncoding ?? String($0) }
    }

    static func threadId(_ parts: [String]) -> String? {
        guard parts.first == "thread", parts.count > 1, !parts[1].isEmpty else { return nil }
        if parts[1] == "t" { return parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil }
        return parts[1]
    }

    /// The panel's own chat rooms (the salotto, an agent's private room) are not threads the app lists.
    static func isPanelRoom(_ id: String) -> Bool { id == "web" || id.hasPrefix("web-") }

    static func roomRoute(_ id: String, url: String?) -> NoticeRoute {
        if id.hasPrefix("web-"), !id.hasPrefix("web-owner-") { return .agent(String(id.dropFirst(4))) }
        return .panel(url ?? "/#/salotto")
    }
}
