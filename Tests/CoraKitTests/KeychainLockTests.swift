#if os(macOS)
import CoraKit
import Foundation
import Security
import Testing

struct KeychainLockTests {
    @Test func detectsLockEvenWhenThereAreNoCredentials() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let password = UUID().uuidString
        var reference: SecKeychain?
        let status = SecKeychainCreate(folder.appendingPathComponent("empty.keychain").path, UInt32(password.utf8.count), password, false, nil, &reference)
        try #require(status == errSecSuccess)
        let keychain = try #require(reference)
        defer { SecKeychainDelete(keychain) }
        #expect(try Keychain.isUnlocked(keychain))
        try #require(SecKeychainLock(keychain) == errSecSuccess)
        #expect(try !Keychain.isUnlocked(keychain))
        try #require(SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true) == errSecSuccess)
        #expect(try Keychain.isUnlocked(keychain))
    }
}
#endif
