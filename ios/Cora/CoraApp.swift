import CoraKit
import SwiftUI

@main
struct CoraApp: App {
    @StateObject private var spaces = Spaces()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(spaces: spaces)
                .onOpenURL { spaces.handle($0) }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: spaces.startAll()
                    case .background: spaces.pauseAll()
                    default: break
                    }
                }
        }
    }
}

enum Tab: String, Hashable { case agents, subscriptions, threads, spaces }

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
    @State private var agentPath: [String] = ProcessInfo.processInfo.environment["CORA_DEMO_AGENT"].map { [$0] } ?? []

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $agentPath) { AgentsView(store: store).toolbar { SpaceMenu(spaces: spaces, store: store) } }
                .tabItem { Label("Agents", systemImage: "person.2") }.tag(Tab.agents)
            NavigationStack { SubscriptionsView(store: store).toolbar { SpaceMenu(spaces: spaces, store: store) } }
                .tabItem { Label("Subscriptions", systemImage: "gauge.with.dots.needle.33percent") }.tag(Tab.subscriptions)
            NavigationStack { ThreadsView(store: store).toolbar { SpaceMenu(spaces: spaces, store: store) } }
                .tabItem { Label("Threads", systemImage: "text.bubble") }.tag(Tab.threads)
            NavigationStack { SpacesView(spaces: spaces) }
                .tabItem { Label("Spaces", systemImage: "square.stack") }.tag(Tab.spaces)
        }
        .onChange(of: store.revoked) { _, revoked in if revoked { spaces.forget(store) } }
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
        }
    }
}
