import CoraKit
import CryptoKit
import SwiftUI
import WebKit

@MainActor
enum PanelSession {
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    private static func identifier(_ connection: Connection) -> UUID {
        let key = connection.server.absoluteString + "/" + connection.deviceId
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        let id = bytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        return UUID(uuid: id)
    }

    static func dataStore(_ connection: Connection) -> WKWebsiteDataStore {
        let id = identifier(connection)
        if let store = stores[id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = store
        return store
    }

    private struct SavedCookie: Codable {
        let value: String
        let expires: Date
    }

    private static let service = "space.usecora.ios.panel"

    static func save(_ cookie: HTTPCookie, for connection: Connection) async throws {
        guard let expires = cookie.expiresDate else { throw ClientError.invalidResponse }
        let saved = try JSONEncoder().encode(SavedCookie(value: cookie.value, expires: expires))
        try Keychain.write(String(decoding: saved, as: UTF8.self), service: service, account: identifier(connection).uuidString)
        await dataStore(connection).httpCookieStore.setCookie(cookie)
    }

    static func restore(_ connection: Connection) async -> Bool {
        let jar = dataStore(connection).httpCookieStore
        let secure = connection.server.scheme == "https"
        let name = secure ? "__Host-cora_session" : "cora_session"
        if await jar.allCookies().contains(where: { $0.name == name && $0.domain == connection.server.host }) { return true }
        let account = identifier(connection).uuidString
        guard let encoded = try? Keychain.read(service: service, account: account),
              let saved = try? JSONDecoder().decode(SavedCookie.self, from: Data(encoded.utf8)),
              saved.expires > Date() else { return false }
        let age = Int(saved.expires.timeIntervalSinceNow)
        let header = "\(name)=\(saved.value); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(age)" + (secure ? "; Secure" : "")
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: connection.server).first else { return false }
        await jar.setCookie(cookie)
        return true
    }

    static func clear(_ connection: Connection) async {
        Keychain.delete(service: service, account: identifier(connection).uuidString)
        let store = dataStore(connection)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        stores.removeValue(forKey: identifier(connection))
    }
}

struct SpacePanel: View {
    let connection: Connection
    @ObservedObject var spaces: Spaces
    @State private var attempt = 0
    @State private var problem: String?
    @State private var needsAuthorization = false
    @State private var ready = false

    var body: some View {
        Group {
            if let problem {
                ContentUnavailableView {
                    Label("Space unavailable", systemImage: "wifi.exclamationmark")
                } description: { Text(problem) } actions: {
                    Button("Try again") { self.problem = nil; attempt += 1 }
                }
            } else if needsAuthorization {
                ContentUnavailableView {
                    Label("Open this space", systemImage: "globe")
                } description: {
                    Text("Authorize the panel with the account you use in Spaces.")
                } actions: {
                    Button("Authorize this iPhone") { spaces.authorize(origin: connection.server) }
                        .buttonStyle(.borderedProminent)
                    if case .failed(let message) = spaces.pairing { Text(message).font(.footnote) }
                }
            } else if ready {
                PanelBrowser(connection: connection, onFailure: { problem = $0 })
            } else {
                ProgressView()
            }
        }
        .task(id: attempt) {
            ready = false
            let hasCookie = await PanelSession.restore(connection)
            if !hasCookie {
                do {
                    let url = connection.server.appendingPathComponent("api/me")
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                    request.httpShouldHandleCookies = false
                    let (data, _) = try await URLSession.shared.data(for: request)
                    let info = try JSONDecoder().decode(PanelSupport.self, from: data)
                    if info.appPanelPairing == true { needsAuthorization = true; return }
                } catch is CancellationError { return }
                catch { if Task.isCancelled { return } }
            }
            ready = true
        }
    }

    private struct PanelSupport: Decodable { var appPanelPairing: Bool? }
}

private struct PanelBrowser: UIViewRepresentable {
    let connection: Connection
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = PanelSession.dataStore(connection)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: connection.server))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onFailure: (String) -> Void
        init(onFailure: @escaping (String) -> Void) { self.onFailure = onFailure }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onFailure(error.localizedDescription) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil, let url = action.request.url, ["http", "https"].contains(url.scheme) {
                UIApplication.shared.open(url)
            }
            return nil
        }
    }
}
