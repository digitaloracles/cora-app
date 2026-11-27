import AppKit
import Combine
import CoraKit
import SwiftUI
import WebKit

/// Where the window's browser points: the space on this Mac or one on a server.
enum PanelTarget: Hashable {
    case local
    case remote(URL)

    var origin: URL {
        switch self {
        case .local: LocalSpace.server
        case .remote(let server): server
        }
    }
}

/// The panel in a browser of the app's own: one web view, its history and its sign-in kept between launches.
@MainActor
final class PanelBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    let web: WKWebView
    /// `cora://` links the panel opens, such as connecting this Mac to the menu bar.
    var onCoraLink: (URL) -> Void = { _ in }
    private var observers: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        // Sign-in pages (Google among them) refuse browsers they do not recognize.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.setAccessibilityIdentifier("panel")
        observers = [
            web.observe(\.canGoBack) { [weak self] web, _ in let value = web.canGoBack; Task { @MainActor in self?.canGoBack = value } },
            web.observe(\.canGoForward) { [weak self] web, _ in let value = web.canGoForward; Task { @MainActor in self?.canGoForward = value } },
            web.observe(\.isLoading) { [weak self] web, _ in let value = web.isLoading; Task { @MainActor in self?.loading = value } },
        ]
    }

    func open(_ url: URL, cookies: [HTTPCookie] = []) async {
        let jar = web.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies { await jar.setCookie(cookie) }
        failure = nil
        web.load(URLRequest(url: url))
    }

    func back() { web.goBack() }
    func forward() { web.goForward() }
    func reload() { failure = nil; web.reload() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.allow) }
        if scheme == "cora" { onCoraLink(url); return decisionHandler(.cancel) }
        if !["http", "https", "about", "blob", "data"].contains(scheme) { NSWorkspace.shared.open(url); return decisionHandler(.cancel) }
        decisionHandler(.allow)
    }

    /// Links that open a new tab go to the person's browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { failure = nil }

    private func failed(_ error: Error) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled, code != 102 else { return }
        failure = error.localizedDescription
    }
}

struct WebPanel: NSViewRepresentable {
    let browser: PanelBrowser
    func makeNSView(context: Context) -> WKWebView { browser.web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// What the window shows: the choice for a first space, the creation of the one on this Mac, the address of a
/// remote one, or the panel itself.
@MainActor
final class PanelModel: ObservableObject {
    enum Screen: Equatable { case welcome, createLocal, connectRemote, panel }

    @Published var screen: Screen = .welcome
    @Published private(set) var target: PanelTarget?
    let browser = PanelBrowser()
    let local: LocalSpaceController
    let spaces: Spaces
    private var watchers: [AnyCancellable] = []
    private var remotesBefore: Set<URL> = []

    init(spaces: Spaces, local: LocalSpaceController) {
        self.spaces = spaces
        self.local = local
        browser.onCoraLink = { [weak spaces] url in spaces?.handle(url) }
        watchers = [
            spaces.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.spacesChanged() } },
            local.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.objectWillChange.send() } },
        ]
        if local.exists { target = .local; screen = .panel }
        else if let first = remotes.first { target = .remote(first); screen = .panel }
    }

    /// The spaces on servers this Mac is connected to.
    var remotes: [URL] { spaces.stores.compactMap { $0.connection?.server }.filter { !Space.isLoopback($0) } }

    func name(_ target: PanelTarget) -> String {
        switch target {
        case .local: return String(localized: "This Mac")
        case .remote(let server):
            return spaces.stores.first { $0.connection?.server == server }?.title ?? server.host ?? server.absoluteString
        }
    }

    /// Opens the panel of a space; `page` is the panel's own route, e.g. `#/agent/<id>/chat`.
    func show(_ target: PanelTarget, page: String = "") {
        self.target = target
        screen = .panel
        Task {
            let address = URL(string: target.origin.absoluteString + "/" + page)!
            switch target {
            case .local:
                await local.ensureRunning()
                let cookies = (try? await local.signIn()) ?? []
                await browser.open(address, cookies: cookies)
            case .remote:
                await browser.open(address)
            }
        }
    }

    /// An agent the menu bar asked for, in the panel of the space the menu bar shows.
    func showAgent(_ id: String?) {
        let server = spaces.current.connection?.server
        let wanted: PanelTarget? = server.map { Space.isLoopback($0) ? .local : .remote($0) } ?? target
        guard let wanted else { return }
        let page = id.flatMap { $0.hasPrefix("#") ? nil : "#/agent/\($0)/chat" } ?? ""
        if page.isEmpty, wanted == target, browser.web.url != nil { screen = .panel; return }
        show(wanted, page: page)
    }

    func createLocal() {
        screen = .createLocal
        Task {
            guard await local.create() else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            show(.local, page: local.agentId.map { "#/agent/\($0)/chat" } ?? "")
        }
    }

    func beginRemote() {
        remotesBefore = Set(remotes)
        if !spaces.stores.isEmpty { spaces.beginAdding() }
        screen = .connectRemote
    }

    func cancelRemote() {
        spaces.cancelAdding()
        screen = target == nil ? .welcome : .panel
    }

    /// The store the address field writes into: the one being added, or the first one of this Mac.
    var connecting: SpaceStore { spaces.adding ?? spaces.current }

    private func spacesChanged() {
        objectWillChange.send()
        guard screen == .connectRemote, let server = remotes.first(where: { !remotesBefore.contains($0) }) else { return }
        show(.remote(server))
    }
}

struct PanelWindowView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, browser: model.browser)
            Divider()
            switch model.screen {
            case .panel:
                ZStack {
                    WebPanel(browser: model.browser)
                    if let failure = model.browser.failure { PanelProblem(message: failure, retry: model.browser.reload) }
                }
            case .welcome: Welcome(model: model)
            case .createLocal: CreateLocal(model: model, local: model.local)
            case .connectRemote: ConnectRemote(model: model, store: model.connecting)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// The window's bar, beside the traffic lights: which space, the browser's arrows, its address.
struct TopBar: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var browser: PanelBrowser

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 70, height: 1)
            spaceMenu
            if model.screen == .panel {
                HStack(spacing: 2) {
                    bar("chevron.left", String(localized: "Back"), enabled: browser.canGoBack, browser.back)
                    bar("chevron.right", String(localized: "Forward"), enabled: browser.canGoForward, browser.forward)
                    bar(browser.loading ? "xmark" : "arrow.clockwise", browser.loading ? String(localized: "Stop") : String(localized: "Reload"), enabled: true) {
                        if browser.loading { browser.web.stopLoading() } else { browser.reload() }
                    }
                }
            }
            Spacer(minLength: 8)
            if model.screen == .panel, let target = model.target {
                Text(verbatim: address(target)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                bar("safari", String(localized: "Open in the browser"), enabled: browser.web.url != nil) {
                    if let url = browser.web.url { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.bar)
    }

    func address(_ target: PanelTarget) -> String {
        let origin = target.origin
        return (origin.host ?? "") + (origin.port.map { ":\($0)" } ?? "")
    }

    var spaceMenu: some View {
        Menu {
            if model.local.exists {
                Button { model.show(.local) } label: { Label(String(localized: "This Mac"), systemImage: "laptopcomputer") }
            }
            ForEach(model.remotes, id: \.self) { server in
                Button { model.show(.remote(server)) } label: { Label(model.name(.remote(server)), systemImage: "globe") }
            }
            Divider()
            if !model.local.exists { Button(String(localized: "Create a space on this Mac…")) { model.screen = .createLocal } }
            Button(String(localized: "Connect a remote space…")) { model.beginRemote() }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityIdentifier("space-menu")
        .help(String(localized: "Choose the space"))
    }

    var title: String {
        switch model.screen {
        case .panel: return model.target.map(model.name) ?? "Cora"
        case .welcome: return "Cora"
        case .createLocal: return String(localized: "This Mac")
        case .connectRemote: return String(localized: "Remote space")
        }
    }

    var dot: Color {
        guard model.screen == .panel else { return Color.secondary.opacity(0.5) }
        if browser.failure != nil { return .orange }
        return browser.loading ? HeatPalette.amber : .green
    }

    func bar(_ symbol: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 24) }
            .buttonStyle(.borderless).disabled(!enabled).help(help).accessibilityLabel(help)
    }
}

/// The first launch: where the space lives. Two real choices, side by side.
struct Welcome: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76)
            Text("Where should your space run?").font(.system(size: 24, weight: .semibold)).padding(.top, 14)
            Text("Agents live in a space: their chats, memory, plans and routines. Keep it on this Mac or connect one you already have.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460).padding(.top, 6)
            HStack(alignment: .top, spacing: 14) {
                ChoiceTile(symbol: "laptopcomputer", title: String(localized: "On this Mac"),
                           text: String(localized: "Cora installs here and starts with your Mac. The agents run on your DeepSeek key."),
                           note: String(localized: "Works while the Mac is awake"), identifier: "choice-local") { model.screen = .createLocal }
                ChoiceTile(symbol: "globe", title: String(localized: "Remote space"),
                           text: String(localized: "Open a space on usecora.space or on your own server, signed in as you are in the browser."),
                           note: String(localized: "Agents keep working when the Mac is off"), identifier: "choice-remote") { model.beginRemote() }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 600).padding(.top, 26)
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ChoiceTile: View {
    let symbol: String
    let title: String
    let text: String
    let note: String
    let identifier: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(HeatPalette.amber).frame(height: 28)
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Label(note, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover ? HeatPalette.amber.opacity(0.9) : Color.primary.opacity(0.1), lineWidth: hover ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }
}

/// The space on this Mac: the key, the first agent's name, then every step as it really happens.
struct CreateLocal: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var local: LocalSpaceController
    @FocusState private var keyFocused: Bool

    var started: Bool { local.running || !local.states.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("A space on this Mac").font(.system(size: 22, weight: .semibold))
                        Text("Cora runs here, on 127.0.0.1, and only this Mac reaches it.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                if !local.exists || local.failure != nil, !local.finished {
                    form.padding(.top, 24)
                }
                if started { steps.padding(.top, 26) }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 36).padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
        .onAppear { keyFocused = true }
    }

    var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("DeepSeek key").font(.system(size: 12, weight: .medium)).gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(String(localized: "sk-…"), text: $local.deepseekKey)
                            .textFieldStyle(.roundedBorder).focused($keyFocused).accessibilityIdentifier("deepseek-key")
                            .onSubmit(create)
                        HStack(spacing: 4) {
                            Text("It stays in this Mac's space, readable only by you.").foregroundStyle(.secondary)
                            Link(String(localized: "Get a key"), destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                        }
                        .font(.system(size: 11))
                    }
                }
                GridRow {
                    Text("First agent").font(.system(size: 12, weight: .medium))
                    TextField(String(localized: "Name"), text: $local.agentName).textFieldStyle(.roundedBorder).frame(maxWidth: 220).accessibilityIdentifier("agent-name")
                        .onSubmit(create)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    buttons.padding(.top, 4)
                }
            }
            .disabled(local.running)
        }
    }

    var buttons: some View {
        HStack(spacing: 10) {
            Button(action: create) {
                Text(local.failure == nil ? String(localized: "Create the space") : String(localized: "Try again")).frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent).tint(HeatPalette.amber).controlSize(.large)
            .keyboardShortcut(.defaultAction).disabled(local.running).accessibilityIdentifier("create-space")
            Button(String(localized: "Back")) { model.screen = model.target == nil ? .welcome : .panel }
                .controlSize(.large).disabled(local.running)
        }
    }

    func create() {
        guard !local.running else { return }
        model.createLocal()
    }

    var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(LocalSpaceController.Step.allCases) { step in
                StepLine(step: step, state: local.state(step), activity: local.state(step) == .running ? local.activity : "",
                         last: step == LocalSpaceController.Step.allCases.last)
            }
            if local.finished {
                Label("The space is ready. Opening the panel…", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.green).padding(.top, 14).padding(.leading, 2)
                    .accessibilityIdentifier("space-ready")
            }
        }
    }
}

/// One step of the creation: a dot on a line, its title and what it does or what is happening now.
struct StepLine: View {
    let step: LocalSpaceController.Step
    let state: LocalSpaceController.State
    let activity: String
    let last: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                marker.frame(width: 22, height: 22)
                if !last { Rectangle().fill(state == .done ? Color.green.opacity(0.5) : Color.primary.opacity(0.12)).frame(width: 2).frame(minHeight: 18, maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title).font(.system(size: 13, weight: state == .running ? .semibold : .medium))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                switch state {
                case .failed(let message):
                    Text(message).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                case .running where !activity.isEmpty:
                    Text(verbatim: activity).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                default:
                    Text(step.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2).padding(.bottom, last ? 0 : 14)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder var marker: some View {
        switch state {
        case .pending: Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5).frame(width: 14, height: 14)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 15)).foregroundStyle(.orange)
        }
    }
}

/// A space on a server: its address, then the authorization in the panel, as the menu bar does.
struct ConnectRemote: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var store: SpaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "globe").font(.system(size: 30)).foregroundStyle(HeatPalette.amber)
            Text("Connect a remote space").font(.system(size: 22, weight: .semibold))
            Text("Type the space's address. Its panel opens in your browser: sign in and authorize this Mac, then Cora opens it here.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Space address"), text: $store.spaceInput, prompt: Text(verbatim: "yourspace.usecora.space"))
                .textFieldStyle(.roundedBorder).controlSize(.large).onSubmit { store.authorize() }.accessibilityIdentifier("remote-address")
            HStack(spacing: 10) {
                Button(String(localized: "Connect")) { store.authorize() }.buttonStyle(.borderedProminent).tint(HeatPalette.amber).controlSize(.large)
                Button(String(localized: "Back")) { model.cancelRemote() }.controlSize(.large)
                switch store.phase {
                case .waitingForPanel(let host):
                    ProgressView().controlSize(.small)
                    Text("Authorize this Mac on \(host)…").font(.system(size: 12)).foregroundStyle(.secondary)
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.system(size: 12)).foregroundStyle(.secondary)
                default: EmptyView()
                }
            }
            if case .failed(let message) = store.phase {
                Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PanelProblem: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 28)).foregroundStyle(.orange)
            Text("The panel did not open").font(.system(size: 15, weight: .semibold))
            Text(verbatim: message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Button(String(localized: "Reload"), action: retry).controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
