import CoraKit
import SwiftUI

enum PopoverTab: String, CaseIterable, Identifiable {
    case agents, tokens, subscriptions, threads
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .agents: return "Agents"
        case .tokens: return "Tokens"
        case .subscriptions: return "Subscriptions"
        case .threads: return "Threads"
        }
    }
}

/// The menu bar popover: the space, then four tabs. Agents with what they do now; Tokens with each agent's tokens in
/// the last 7 days; Subscriptions with one line per subscription (each one can be pinned to the menu bar); Threads with
/// the latest reasoning of each thread. The popover is as tall as the tab's content and scrolls only past the screen.
struct PopoverView: View {
    @ObservedObject var store: SpaceStore
    /// The other spaces of this Mac: the switcher under the header, and "Add another space" in the menu.
    var spaces: Spaces? = nil
    var openAgent: (String?) -> Void = { _ in }
    @State var tab: PopoverTab = .agents
    @State var threadQuery = ""
    @State var agentQuery = ""
    @Environment(\.isStaticPreview) private var isStaticPreview

    var body: some View {
        VStack(spacing: 0) {
            header
            if let spaces, spaces.stores.count > 1 || spaces.adding != nil {
                SpaceSwitcher(spaces: spaces).padding(.horizontal, 10).padding(.bottom, 10)
            }
            Divider()
            if let snapshot = store.snapshot {
                Picker("", selection: $tab) {
                    ForEach(PopoverTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
                if tab == .agents { SearchField(query: $agentQuery, prompt: String(localized: "Search agents")).padding(.horizontal, 10).padding(.top, 8) }
                if tab == .threads { SearchField(query: $threadQuery, prompt: String(localized: "Search threads")).padding(.horizontal, 10).padding(.top, 8) }
                scrolling {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case .agents: agents(snapshot)
                        case .tokens: tokens(snapshot)
                        case .subscriptions: subscriptions(snapshot)
                        case .threads: threads(snapshot)
                        }
                    }
                    .padding(10)
                }
            } else {
                ConnectPanel(store: store, cancel: spaces?.adding === store ? { spaces?.cancelAdding() } : nil).padding(16)
            }
        }
        .frame(width: 360)
    }

    @ViewBuilder func agents(_ snapshot: Snapshot) -> some View {
        let list = Agent.matching(snapshot.agents, agentQuery)
        if snapshot.agents.isEmpty {
            empty("No agents in this space for your account.")
        } else if list.isEmpty {
            empty("No agent matches your search.")
        }
        ForEach(list) { agent in
            Button { openAgent(agent.id) } label: { AgentRow(agent: agent, url: store.avatarURL(agent), live: liveLine(agent)) }
                .buttonStyle(.plain)
        }
    }

    func tokens(_ snapshot: Snapshot) -> some View {
        TokensSummary(store: store, snapshot: snapshot, openAgent: { openAgent($0) }, showSubscriptions: false)
    }

    func subscriptions(_ snapshot: Snapshot) -> some View {
        TokensSummary(store: store, snapshot: snapshot, showTokens: false)
    }

    @ViewBuilder func threads(_ snapshot: Snapshot) -> some View {
        let all = ThreadEntry.all(snapshot)
        let list = ThreadEntry.matching(all, threadQuery)
        if all.isEmpty { empty("No threads yet.") } else if list.isEmpty { empty("No thread matches your search.") }
        ForEach(list) { entry in
            Button { openAgent(entry.agents.first?.id) } label: { ThreadRow(entry: entry, avatarURL: { store.avatarURL($0) }) }.buttonStyle(.plain)
        }
    }

    func empty(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 2)
    }

    /// The tab's content at its full height. A bare ScrollView has no height of its own, so the popover used to
    /// collapse to a short box and scroll even with room to spare: the scroll view now takes the measured height of
    /// what it holds, and scrolls only when that is taller than the screen allows. A static render has no scroll view.
    @ViewBuilder func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if isStaticPreview {
            content()
        } else {
            ScrollView {
                content().background(GeometryReader { proxy in Color.clear.preference(key: ContentHeight.self, value: proxy.size.height) })
            }
            .frame(height: min(max(contentHeight, 40), Self.maxContentHeight))
            .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
        }
    }

    @State private var contentHeight: CGFloat = 0

    /// The room under the menu bar, less the header and the tabs.
    static var maxContentHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, visible - 150)
    }

    var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.snapshot?.space.name ?? store.connection?.spaceName ?? "Cora").font(.system(size: 13, weight: .semibold))
                if let snapshot = store.snapshot {
                    Text(subtitle(snapshot)).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Not connected").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.snapshot != nil {
                Circle().fill(store.streamOnline || isStaticPreview ? Color.green : Color.orange).frame(width: 6, height: 6)
                    .help(store.streamOnline ? String(localized: "Live") : String(localized: "Reconnecting to the live stream…"))
                Button { openAgent(tab == .tokens ? LiveSelection.tokens : nil) } label: { Image(systemName: "macwindow") }.buttonStyle(.borderless).help(String(localized: "Open the live window"))
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help(String(localized: "Refresh"))
            }
            Menu {
                if let connection = store.connection {
                    Text("Signed in as \(connection.userName)")
                    Button(String(localized: "Open the panel")) { NSWorkspace.shared.open(connection.server) }
                    Button(String(localized: "Disconnect this Mac from \(connection.host)")) { Task { await store.disconnect() } }
                    Divider()
                }
                if let spaces, !spaces.stores.isEmpty, spaces.adding == nil {
                    Button(String(localized: "Add another space…")) { spaces.beginAdding() }
                    Divider()
                }
                Button(String(localized: "Quit Cora")) { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    func subtitle(_ snapshot: Snapshot) -> String {
        let working = snapshot.working.count
        let who = snapshot.user.name
        return working == 0 ? String(localized: "\(who) · nobody working") : String(localized: "\(who) · \(working) working")
    }

    func liveLine(_ agent: Agent) -> String? {
        guard let live = agent.live.first else { return nil }
        let step = store.stepsFor(live.traceId).last ?? live.lastStep
        return step?.headline.replacingOccurrences(of: "\n", with: " ")
    }

    @ViewBuilder func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 2)
            content()
        }
    }
}

struct AgentRow: View {
    let agent: Agent
    let url: URL?
    let live: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatar(agent: agent, url: url, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.system(size: 13, weight: .semibold))
                    StateBadge(state: agent.state)
                    Spacer(minLength: 0)
                    Text(Format.tokens(agent.usage.today.total)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .help(String(localized: "Tokens today"))
                }
                if let live, !live.isEmpty {
                    Text(live).font(.system(size: 11)).italic().foregroundStyle(.secondary).lineLimit(2)
                } else if let thread = agent.live.first?.threadName, !thread.isEmpty {
                    Text(thread).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("\(Format.model(agent.model)) · \(Format.tokens(agent.usage.week.total)) in 7 days")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(agent.state == .working ? 0.07 : 0.035)))
        .contentShape(Rectangle())
    }
}

/// Before a space is connected: the address, then the panel authorizes this Mac.
struct ConnectPanel: View {
    @ObservedObject var store: SpaceStore
    /// Set while adding one more space: goes back to the spaces already connected.
    var cancel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(cancel == nil ? "Connect your space" : "Add another space").font(.system(size: 13, weight: .semibold))
            Text("The panel opens in your browser. Sign in there and authorize this Mac: Cora comes back here on its own.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Space address"), text: $store.spaceInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.authorize() }
            HStack {
                Button(String(localized: "Connect")) { store.authorize() }.buttonStyle(.borderedProminent).controlSize(.small)
                if let cancel { Button(String(localized: "Cancel"), action: cancel).controlSize(.small) }
                switch store.phase {
                case .waitingForPanel(let host):
                    ProgressView().controlSize(.small)
                    Text("Authorize this Mac on \(host)…").font(.system(size: 11)).foregroundStyle(.secondary)
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.system(size: 11)).foregroundStyle(.secondary)
                default: EmptyView()
                }
            }
            if case .failed(let message) = store.phase {
                Label(message, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Read-only: the app never changes your agents or settings.").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

/// One thread with the agents that work in it, newest first.
struct ThreadEntry: Identifiable {
    var thread: ThreadInfo
    var agents: [Agent]
    var id: String { thread.id }

    static func all(_ snapshot: Snapshot) -> [ThreadEntry] {
        var order: [String] = [], entries: [String: ThreadEntry] = [:]
        for agent in snapshot.agents {
            for thread in agent.threads {
                if var entry = entries[thread.id] {
                    entry.agents.append(agent)
                    if (thread.lastAt ?? .distantPast) > (entry.thread.lastAt ?? .distantPast) { entry.thread = thread }
                    entries[thread.id] = entry
                } else {
                    order.append(thread.id); entries[thread.id] = ThreadEntry(thread: thread, agents: [agent])
                }
            }
        }
        return order.compactMap { entries[$0] }.sorted(by: newestFirst)
    }

    static func newestFirst(_ a: ThreadEntry, _ b: ThreadEntry) -> Bool {
        let (x, y) = (a.thread.lastAt ?? .distantPast, b.thread.lastAt ?? .distantPast)
        return x != y ? x > y : a.thread.name.localizedStandardCompare(b.thread.name) == .orderedAscending
    }

    /// Every word of the query must appear in the thread's name, its agents or its latest reasoning.
    static func matching(_ list: [ThreadEntry], _ query: String) -> [ThreadEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return list }
        return list.filter { entry in
            let text = ([entry.thread.name, entry.thread.reasoning] + entry.agents.map(\.name)).joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

struct SearchField: View {
    @Binding var query: String
    var prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(prompt, text: $query).textFieldStyle(.plain).font(.system(size: 12))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help(String(localized: "Clear"))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// The agents of a thread as small overlapping avatars.
struct AvatarStack: View {
    let agents: [Agent]
    let url: (Agent) -> URL?
    var size: CGFloat = 16

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(agents.prefix(5)) { agent in
                AgentAvatar(agent: agent, url: url(agent), size: size, ring: false)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5).padding(-1))
            }
        }
    }
}

struct ThreadRow: View {
    let entry: ThreadEntry
    var avatarURL: (Agent) -> URL? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(active ? Color.green : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                Text(entry.thread.name.isEmpty ? entry.thread.id : entry.thread.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let at = entry.thread.lastAt { Text(Format.ago(at)).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                AvatarStack(agents: entry.agents, url: avatarURL)
                Text(([entry.agents.map(\.name).joined(separator: ", ")] + (tokens > 0 ? [Format.tokens(tokens) + " token"] : [])).joined(separator: " · "))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            if !entry.thread.reasoning.isEmpty {
                Text(entry.thread.reasoning.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 11)).italic().foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(active ? 0.07 : 0.035)))
        .contentShape(Rectangle())
    }

    var active: Bool { entry.thread.status == "active" }
    var tokens: Int { entry.thread.tokensIn + entry.thread.tokensOut }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The popover of the space on screen; it follows the switcher.
struct SpacesPopover: View {
    @ObservedObject var spaces: Spaces
    var openAgent: (String?) -> Void = { _ in }

    var body: some View {
        PopoverView(store: spaces.current, spaces: spaces, openAgent: openAgent).id(ObjectIdentifier(spaces.current))
    }
}

/// One chip per space, with how many agents work there now; the last one adds a space.
struct SpaceSwitcher: View {
    @ObservedObject var spaces: Spaces

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(spaces.stores.enumerated()), id: \.offset) { chip($0.element) }
                if let adding = spaces.adding { chip(adding) }
                else {
                    Button { spaces.beginAdding() } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22) }
                        .buttonStyle(.plain).background(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                        .help(String(localized: "Add another space…"))
                }
            }
        }
    }

    func chip(_ store: SpaceStore) -> some View {
        let selected = spaces.current === store
        let working = store.snapshot?.working.count ?? 0
        return Button { spaces.select(store) } label: {
            HStack(spacing: 5) {
                Circle().fill(store.phase == .ready ? (working > 0 ? HeatPalette.amber : Color.green) : Color.orange).frame(width: 6, height: 6)
                Text(store.title).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1)
                if working > 0 { Text("\(working)").font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(store.connection?.host ?? "")
    }
}
