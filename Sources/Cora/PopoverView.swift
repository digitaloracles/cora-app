import CoraKit
import SwiftUI

/// The menu bar popover: the space, every agent with what it is doing now, then the accounts and their quotas.
struct PopoverView: View {
    @ObservedObject var store: SpaceStore
    var openAgent: (String?) -> Void = { _ in }
    @Environment(\.isStaticPreview) private var isStaticPreview

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let snapshot = store.snapshot {
                scrolling {
                    VStack(alignment: .leading, spacing: 14) {
                        section("Agents") {
                            if snapshot.agents.isEmpty {
                                Text("No agents in this space for your account.").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            ForEach(snapshot.agents) { agent in
                                Button { openAgent(agent.id) } label: { AgentRow(agent: agent, url: store.avatarURL(agent), live: liveLine(agent)) }
                                    .buttonStyle(.plain)
                            }
                        }
                        section("Quotas") {
                            if snapshot.accounts.isEmpty {
                                Text("No subscription is linked to your agents.").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            ForEach(snapshot.accounts) { account in
                                AccountCard(account: account, agents: snapshot.agents.filter { account.agentIds.contains($0.id) })
                            }
                        }
                    }
                    .padding(10)
                }
            } else {
                ConnectPanel(store: store).padding(16)
            }
        }
        .frame(width: 360)
    }

    /// A static render has no scroll view: it shows the whole list.
    @ViewBuilder func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if isStaticPreview { content() } else { ScrollView { content() }.frame(maxHeight: 560) }
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
                Button { openAgent(nil) } label: { Image(systemName: "macwindow") }.buttonStyle(.borderless).help(String(localized: "Open the live window"))
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help(String(localized: "Refresh"))
            }
            Menu {
                if let connection = store.connection {
                    Text("Signed in as \(connection.userName)")
                    Button(String(localized: "Open the panel")) { NSWorkspace.shared.open(connection.server) }
                    Button(String(localized: "Disconnect this Mac")) { Task { await store.disconnect() } }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your space").font(.system(size: 13, weight: .semibold))
            Text("The panel opens in your browser. Sign in there and authorize this Mac: Cora comes back here on its own.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(String(localized: "Space address"), text: $store.spaceInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.authorize() }
            HStack {
                Button(String(localized: "Connect")) { store.authorize() }.buttonStyle(.borderedProminent).controlSize(.small)
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
