import Foundation
import Security

/// The `cora://connect` link a Cora panel opens after the person signed in there authorizes this Mac.
public struct ConnectLink: Equatable, Sendable {
    public let server: URL
    public let code: String
    public let state: String?

    public enum Problem: Error, Equatable { case notACoraLink, insecureServer, missingCode }

    public static func parse(_ url: URL) throws -> ConnectLink {
        guard url.scheme?.lowercased() == "cora", url.host?.lowercased() == "connect",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw Problem.notACoraLink }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let raw = value("server"), let server = Space.origin(raw) else { throw Problem.notACoraLink }
        guard server.scheme == "https" || Space.isLoopback(server) else { throw Problem.insecureServer }
        guard let code = value("code"), code.range(of: #"^cora_pair_[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else { throw Problem.missingCode }
        let state = value("state").flatMap { $0.isEmpty ? nil : $0 }
        return ConnectLink(server: server, code: code, state: state)
    }
}

public enum Space {
    /// `notseb.usecora.space`, `https://notseb.usecora.space/#/agenti` and the like become `https://notseb.usecora.space`.
    public static func origin(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = parts.port
        return origin.url
    }

    public static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    }

    /// The panel page where the person signed in to the space authorizes this Mac. The state comes back in the link.
    public static func authorizeURL(origin: URL, state: String) -> URL {
        URL(string: origin.absoluteString + "/#/app?state=" + state)!
    }

    public static func newState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No randomness available")
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
