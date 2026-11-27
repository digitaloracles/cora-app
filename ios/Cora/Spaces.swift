import AuthenticationServices
import CoraKit
import CryptoKit
import WebKit
import Foundation
import UIKit

/// Every space this iPhone reads, the one on screen, and the pairing with a panel.
@MainActor
final class Spaces: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    enum Pairing: Equatable { case idle, waiting(String), connecting, failed(String) }

    @Published private(set) var stores: [SpaceStore] = []
    @Published var selected: URL? {
        didSet {
            if !Self.demo { UserDefaults.standard.set(selected?.absoluteString, forKey: "CoraSelectedSpace") }
        }
    }
    @Published var pairing: Pairing = .idle
    @Published var address = ""
    /// A link the app did not ask for, waiting for the person to confirm it.
    @Published var unrequested: ConnectLink?
    private var session: ASWebAuthenticationSession?
    private var state: String?
    private var verifier: String?
    private var pendingOrigin: URL?

    override init() {
        super.init()
        if Self.demo {
            stores = [SpaceStore(demo: Samples.snapshot, steps: Samples.steps, planReasoning: Samples.planReasoning)]
        } else {
            stores = Storage.loadConnections().map { SpaceStore(connection: $0) }
        }
        let last = UserDefaults.standard.string(forKey: "CoraSelectedSpace")
        selected = stores.first(where: { $0.id.absoluteString == last })?.id ?? stores.first?.id
    }

    /// The sample space. `CORA_DEMO_STICKY=1` keeps it for the next launches too, so a UI test can check a notification tapped after the app was closed.
    static var demo: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["CORA_DEMO"] == "1" && environment["CORA_DEMO_STICKY"] == "1" { UserDefaults.standard.set(true, forKey: "CoraDemoSticky") }
        return environment["CORA_DEMO"] == "1" || UserDefaults.standard.bool(forKey: "CoraDemoSticky")
    }

    var current: SpaceStore? { stores.first { $0.id == selected } ?? stores.first }

    func startAll() { stores.forEach { $0.start() } }

    /// Gives this phone's APNs token to every connected space; a space that does not know notifications yet just refuses.
    func registerPush(_ token: String, environment: String) {
        for store in stores { Task { await store.registerPush(token, environment: environment) } }
    }
    func pauseAll() { stores.forEach { $0.pause() } }

    /// Opens the panel of the space, signed in there, to authorize this iPhone; the panel answers with a cora:// link.
    func authorize() {
        guard let origin = Space.origin(address) else {
            pairing = .failed(String(localized: "Write the address of your space, for example yourspace.usecora.space."))
            return
        }
        authorize(origin: origin)
    }

    func authorize(origin: URL) {
        guard origin.scheme == "https" || Space.isLoopback(origin) else {
            pairing = .failed(String(localized: "A space needs a secure HTTPS address."))
            return
        }
        let state = Space.newState()
        let verifier = Space.newState()
        self.verifier = verifier
        pendingOrigin = origin
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let url = URL(string: Space.authorizeURL(origin: origin, state: state).absoluteString + "&panel_challenge=" + challenge)!
        self.state = state
        pairing = .waiting(origin.host ?? origin.absoluteString)
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "cora") { [weak self] url, error in
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
        guard link.state != nil, link.state == state, link.server == pendingOrigin else {
            pairing = .idle
            unrequested = link
            return
        }
        let proof = verifier
        state = nil
        verifier = nil
        pendingOrigin = nil
        Task { await connect(link, verifier: proof) }
    }

    func connect(_ link: ConnectLink, verifier: String? = nil) async {
        unrequested = nil
        pairing = .connecting
        do {
            let name = UIDevice.current.name
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            let exchange = URLSession(configuration: config, delegate: PairingTransport(), delegateQueue: nil)
            defer { exchange.finishTasksAndInvalidate() }
            let (paired, cookies) = try await CoraClient.exchange(link, deviceName: name.isEmpty ? "iPhone" : name, platform: "iOS \(UIDevice.current.systemVersion)", panelVerifier: verifier, session: exchange)
            let connection = Connection(server: link.server, spaceName: link.server.host ?? "", userName: paired.user.name, email: paired.user.email, deviceId: paired.device.id)
            if verifier != nil {
                let secure = link.server.scheme == "https"
                let name = secure ? "__Host-cora_session" : "cora_session"
                for cookie in cookies where cookie.name == name && cookie.domain == link.server.host &&
                    cookie.path == "/" && cookie.isHTTPOnly && cookie.isSecure == secure {
                    try await PanelSession.save(cookie, for: connection)
                }
            }
            try Storage.save(connection, token: paired.token)
            if let old = stores.first(where: { $0.id == connection.server }) {
                await PanelSession.clear(old.connection)
            }
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
        await PanelSession.clear(store.connection)
        stores.removeAll { $0.id == store.id }
        if selected == store.id { selected = stores.first?.id }
    }

    /// Drops a space whose access was revoked by the server: the person connects it again.
    func forget(_ store: SpaceStore) {
        store.pause()
        Storage.forget(store.connection)
        Task { await PanelSession.clear(store.connection) }
        stores.removeAll { $0.id == store.id }
        if selected == store.id { selected = stores.first?.id }
    }
}

private final class PairingTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
