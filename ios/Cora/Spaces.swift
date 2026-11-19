import AuthenticationServices
import CoraKit
import Foundation
import UIKit

/// Every space this iPhone reads, the one on screen, and the pairing with a panel.
@MainActor
final class Spaces: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    enum Pairing: Equatable { case idle, waiting(String), connecting, failed(String) }

    @Published private(set) var stores: [SpaceStore] = []
    @Published var selected: URL?
    @Published var pairing: Pairing = .idle
    @Published var address = "notseb.usecora.space"
    /// A link the app did not ask for, waiting for the person to confirm it.
    @Published var unrequested: ConnectLink?
    private var session: ASWebAuthenticationSession?
    private var state: String?

    override init() {
        super.init()
        stores = Storage.loadConnections().map { SpaceStore(connection: $0) }
        selected = stores.first?.id
    }

    var current: SpaceStore? { stores.first { $0.id == selected } ?? stores.first }

    func startAll() { stores.forEach { $0.start() } }
    func pauseAll() { stores.forEach { $0.pause() } }

    /// Opens the panel of the space, signed in there, to authorize this iPhone; the panel answers with a cora:// link.
    func authorize() {
        guard let origin = Space.origin(address) else {
            pairing = .failed(String(localized: "Write the address of your space, for example notseb.usecora.space."))
            return
        }
        let state = Space.newState()
        self.state = state
        pairing = .waiting(origin.host ?? origin.absoluteString)
        let session = ASWebAuthenticationSession(url: Space.authorizeURL(origin: origin, state: state), callbackURLScheme: "cora") { [weak self] url, error in
            Task { @MainActor in
                guard let self else { return }
                if let url { self.handle(url) }
                else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { self.pairing = .idle }
                else { self.pairing = .failed(error?.localizedDescription ?? String(localized: "The panel did not answer.")) }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        if !session.start() { pairing = .failed(String(localized: "The panel could not be opened.")) }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    /// A cora://connect link: from the panel this app opened, or one it did not ask for, which the person confirms first.
    func handle(_ url: URL) {
        let link: ConnectLink
        do { link = try ConnectLink.parse(url) } catch {
            pairing = .failed(String(localized: "This link does not come from a Cora panel."))
            return
        }
        let expected = state
        state = nil
        if link.state == nil || link.state != expected {
            pairing = .idle
            unrequested = link
            return
        }
        Task { await connect(link) }
    }

    func connect(_ link: ConnectLink) async {
        unrequested = nil
        pairing = .connecting
        do {
            let name = UIDevice.current.name
            let paired = try await CoraClient.exchange(link, deviceName: name.isEmpty ? "iPhone" : name, platform: "iOS \(UIDevice.current.systemVersion)")
            let connection = Connection(server: link.server, spaceName: link.server.host ?? "", userName: paired.user.name, email: paired.user.email, deviceId: paired.device.id)
            try Storage.save(connection, token: paired.token)
            stores.first { $0.id == connection.server }?.pause()
            let store = SpaceStore(connection: connection, token: paired.token)
            if let index = stores.firstIndex(where: { $0.id == connection.server }) { stores[index] = store } else { stores.append(store) }
            selected = store.id
            pairing = .idle
            store.start()
        } catch {
            pairing = .failed(error.localizedDescription)
        }
    }

    func signOut(_ store: SpaceStore) async {
        await store.signOut()
        stores.removeAll { $0.id == store.id }
        if selected == store.id { selected = stores.first?.id }
    }

    /// Drops a space whose access was revoked by the server: the person connects it again.
    func forget(_ store: SpaceStore) {
        store.pause()
        Storage.forget(store.connection)
        stores.removeAll { $0.id == store.id }
        if selected == store.id { selected = stores.first?.id }
    }
}
