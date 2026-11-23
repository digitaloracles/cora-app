import CoraKit
import SwiftUI
import UIKit

@main
struct CoraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var spaces = Spaces()
    @StateObject private var notices = Notices.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(spaces: spaces)
                .onOpenURL { spaces.handle($0) }
                .onAppear { notices.scheduleDemoNotice() }
                .onChange(of: notices.token) { _, token in if let token { spaces.registerPush(token, environment: notices.environment) } }
                .onChange(of: spaces.stores.count) { _, count in
                    guard count > 0 && !Spaces.demo else { return }
                    notices.ask()
                    if let token = notices.token { spaces.registerPush(token, environment: notices.environment) }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        spaces.startAll()
                        if !spaces.stores.isEmpty && !Spaces.demo {
                            notices.ask()
                            if let token = notices.token { spaces.registerPush(token, environment: notices.environment) }
                        }
                    case .background: spaces.pauseAll()
                    default: break
                    }
                }
        }
    }
}

enum Tab: String, Hashable { case agents, subscriptions, threads, plans, spaces }

struct RootView: View {
    @ObservedObject var spaces: Spaces
    @State private var tab: Tab = Tab(rawValue: ProcessInfo.processInfo.environment["CORA_DEMO_TAB"] ?? "") ?? .agents

    var body: some View {
        Group {
            if let store = spaces.current {
                SpaceTabs(spaces: spaces, store: store, tab: $tab).id(store.id)
            } else {
                NavigationStack { ConnectView(spaces: spaces).navigationTitle("Cora") }
            }
        }
        // A notice from another connected space switches to it first; that space's tabs then open it.
        .onReceive(Notices.shared.$notice) { notice in
            guard let notice, let current = spaces.current, !notice.belongs(to: current.id),
                  let other = spaces.stores.first(where: { notice.belongs(to: $0.id) }) else { return }
            spaces.selected = other.id
        }
        .alert(unrequestedTitle, isPresented: Binding(get: { spaces.unrequested != nil }, set: { if !$0 { spaces.unrequested = nil } })) {
            Button("Connect") { if let link = spaces.unrequested { Task { await spaces.connect(link) } } }
            Button("Cancel", role: .cancel) { spaces.unrequested = nil }
        } message: {
            Text("The app will read the agents, quotas and live work you see in that space. It cannot change anything.")
        }
    }

    var unrequestedTitle: String {
        String(localized: "Connect this iPhone to \(spaces.unrequested?.server.host ?? "")?")
    }
}

struct SpaceTabs: View {
    @ObservedObject var spaces: Spaces
    @ObservedObject var store: SpaceStore
    @Binding var tab: Tab
    @Environment(\.scenePhase) private var phase
    @State private var agentPath: [String] = ProcessInfo.processInfo.environment["CORA_DEMO_AGENT"].map { [$0] } ?? []
    @State private var threadPath: [ThreadRoute] = ProcessInfo.processInfo.environment["CORA_DEMO_THREAD"].map { [ThreadRoute(id: $0)] } ?? []
    @State private var planPath: [PlanRoute] = ProcessInfo.processInfo.environment["CORA_DEMO_PLAN"].map { [PlanRoute(id: $0)] } ?? []

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $agentPath) { AgentsView(store: store).toolbar { SpaceMenu(spaces: spaces, store: store) } }
                .tabItem { Label("Agents", systemImage: "person.2") }.tag(Tab.agents)
                .badge(store.snapshot?.requests.count ?? 0)
            NavigationStack { SubscriptionsView(store: store).toolbar { SpaceMenu(spaces: spaces, store: store) } }
                .tabItem { Label("Subscriptions", systemImage: "gauge.with.dots.needle.33percent") }.tag(Tab.subscriptions)
            NavigationStack(path: $threadPath) { ThreadsView(store: store).toolbar { SpaceMenu(spaces: spaces, store: store) } }
                .tabItem { Label("Threads", systemImage: "text.bubble") }.tag(Tab.threads)
            NavigationStack(path: $planPath) { PlansView(store: store).toolbar { SpaceMenu(spaces: spaces, store: store) } }
                .tabItem { Label("Plans", systemImage: "checklist") }.tag(Tab.plans)
                .badge(store.snapshot?.plans?.open.count ?? 0)
            NavigationStack { SpacesView(spaces: spaces) }
                .tabItem { Label("Spaces", systemImage: "square.stack") }.tag(Tab.spaces)
        }
        .onChange(of: store.revoked) { _, revoked in if revoked { spaces.forget(store) } }
        // A tap arrives while the app is still coming back to the front, or before these tabs exist when it launched the app:
        // the notice waits in `Notices` and opens once the scene is active.
        .onReceive(Notices.shared.$notice) { notice in if phase == .active { take(notice) } }
        .onChange(of: phase) { _, now in if now == .active { take(Notices.shared.notice) } }
        .task { if phase == .active { take(Notices.shared.notice) } }
    }

    private func take(_ notice: Notice?) {
        guard let notice else { return }
        if !notice.belongs(to: store.id) && spaces.stores.contains(where: { notice.belongs(to: $0.id) }) { return }
        Notices.shared.notice = nil
        open(notice.route)
    }

    /// Opens a tapped notification: its plan, thread or agent on top of its tab, the subscriptions, or the panel page in the browser.
    private func open(_ route: NoticeRoute) {
        switch route {
        case .plan(let id): tab = .plans; planPath = [PlanRoute(id: id)]
        case .thread(let id): tab = .threads; threadPath = [ThreadRoute(id: id)]
        case .agent(let id): tab = .agents; agentPath = [id]
        case .subscriptions: tab = .subscriptions
        case .panel(let path): if let url = Notice.panelURL(path, origin: store.id) { UIApplication.shared.open(url) }
        }
    }
}

/// The space on screen, its live state, and the switch to the other spaces.
struct SpaceMenu: ToolbarContent {
    @ObservedObject var spaces: Spaces
    @ObservedObject var store: SpaceStore

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 6) {
                Circle().fill(store.streamOnline ? Color.green : Color.orange).frame(width: 7, height: 7)
                    .accessibilityLabel(store.streamOnline ? Text("Live") : Text("Reconnecting to the live stream…"))
                if spaces.stores.count > 1 {
                    Menu {
                        Picker("Space", selection: Binding(get: { spaces.selected ?? store.id }, set: { spaces.selected = $0 })) {
                            ForEach(spaces.stores) { Text($0.title).tag($0.id) }
                        }
                    } label: {
                        HStack(spacing: 3) { Text(store.title).font(.subheadline.weight(.semibold)); Image(systemName: "chevron.down").font(.caption2) }
                    }
                } else {
                    Text(store.title).font(.subheadline.weight(.semibold))
                }
            }
            .fixedSize()
            .padding(.horizontal, 4)
        }
    }
}
