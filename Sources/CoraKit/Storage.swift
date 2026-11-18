import Foundation
import Security

/// Which space this Mac reads, without the token: that stays in the Keychain.
public struct Connection: Codable, Equatable, Sendable {
    public var server: URL
    public var spaceName: String
    public var userName: String
    public var email: String
    public var deviceId: String
    public var connectedAt: Date

    public init(server: URL, spaceName: String, userName: String, email: String, deviceId: String, connectedAt: Date = Date()) {
        self.server = server; self.spaceName = spaceName; self.userName = userName; self.email = email; self.deviceId = deviceId; self.connectedAt = connectedAt
    }

    public var host: String { server.host ?? server.absoluteString }
}

public enum Storage {
    /// `CORA_APP_HOME` moves everything, Keychain service included, for tests and side-by-side builds.
    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["CORA_APP_HOME"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cora", isDirectory: true)
    }

    static var keychainService: String {
        if let custom = ProcessInfo.processInfo.environment["CORA_APP_HOME"], !custom.isEmpty { return "space.usecora.app.test" }
        return "space.usecora.app"
    }

    static var connectionsFile: URL { home.appendingPathComponent("connections.json") }
    /// Where versions up to 0.2.10 kept their single space; read once and moved into `connections.json`.
    static var legacyConnectionFile: URL { home.appendingPathComponent("connection.json") }
    public static var pendingStateFile: URL { home.appendingPathComponent("pending-state") }

    /// Every space this Mac reads, in the order they were connected.
    public static func loadConnections() -> [Connection] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: connectionsFile), let list = try? decoder.decode([Connection].self, from: data) { return list }
        guard let data = try? Data(contentsOf: legacyConnectionFile), let single = try? decoder.decode(Connection.self, from: data) else { return [] }
        if (try? write([single])) != nil { try? FileManager.default.removeItem(at: legacyConnectionFile) }
        return [single]
    }

    /// The first space, for the command line.
    public static func loadConnection() -> Connection? { loadConnections().first }

    public static func connection(server: URL) -> Connection? { loadConnections().first { $0.server == server } }

    /// Adds the space, or replaces the one with the same server, keeping its place.
    public static func save(_ connection: Connection, token: String) throws {
        try Keychain.write(token, service: keychainService, account: connection.server.absoluteString)
        var list = loadConnections()
        if let index = list.firstIndex(where: { $0.server == connection.server }) { list[index] = connection } else { list.append(connection) }
        try write(list)
    }

    /// Keeps a name the server changed, without touching the token.
    public static func update(_ connection: Connection) {
        var list = loadConnections()
        guard let index = list.firstIndex(where: { $0.server == connection.server }), list[index] != connection else { return }
        list[index] = connection
        try? write(list)
    }

    static func write(_ list: [Connection]) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: connectionsFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: connectionsFile.path)
    }

    public static func token(for connection: Connection) -> String? {
        try? Keychain.read(service: keychainService, account: connection.server.absoluteString)
    }

    /// Forgets one space: its token and its line; the other spaces stay.
    public static func forget(_ connection: Connection) {
        Keychain.delete(service: keychainService, account: connection.server.absoluteString)
        let list = loadConnections().filter { $0.server != connection.server }
        try? write(list)
    }

    /// The state this Mac sent to the panel, so a link it did not ask for is recognized as such.
    public static func rememberPendingState(_ state: String) {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data((state + "\n" + Instant.format(Date())).utf8).write(to: pendingStateFile, options: .atomic)
    }

    public static func takePendingState(maxAge: TimeInterval = 900) -> String? {
        defer { try? FileManager.default.removeItem(at: pendingStateFile) }
        guard let text = try? String(contentsOf: pendingStateFile, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "\n").map(String.init)
        guard parts.count == 2, let at = Instant.parse(parts[1]), Date().timeIntervalSince(at) < maxAge else { return nil }
        return parts[0]
    }
}

public enum Keychain {
    public enum Failure: Error { case status(OSStatus) }

    static func base(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public static func write(_ value: String, service: String, account: String) throws {
        let query = base(service: service, account: account)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    public static func read(service: String, account: String) throws -> String? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw Failure.status(status) }
        return text
    }

    public static func delete(service: String, account: String) {
        SecItemDelete(base(service: service, account: account) as CFDictionary)
    }
}
