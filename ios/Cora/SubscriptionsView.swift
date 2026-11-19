import CoraKit
import SwiftUI

/// Every subscription of the space with what is left of each limit.
struct SubscriptionsView: View {
    @ObservedObject var store: SpaceStore

    var body: some View {
        Loaded(store: store) { snapshot in
            List {
                if snapshot.accounts.isEmpty { Placeholder(text: String(localized: "No subscriptions in this space.")) }
                ForEach(snapshot.accounts) { account in
                    Section {
                        SubscriptionRow(store: store, account: account, title: title(account, in: snapshot), expanded: true)
                    }
                }
                if let at = store.refreshedAt {
                    Text("Updated \(Format.ago(at))").font(.caption2).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await store.refresh() }
        }
        .navigationTitle("Subscriptions")
    }

    /// The provider, plus the label or the mailbox only when two subscriptions share a provider.
    func title(_ account: Account, in snapshot: Snapshot) -> String {
        let shared = snapshot.accounts.filter { $0.provider == account.provider }.count > 1
        guard shared else { return account.displayName }
        let extra = account.label.isEmpty ? account.email : account.label
        return extra.isEmpty || extra == Providers.name(account.provider) ? Providers.name(account.provider) : "\(Providers.name(account.provider)) · \(extra)"
    }
}

/// One subscription: mark and name, then each limit with what is left, its bar and its reset. Expanded, every limit,
/// balance and detail.
struct SubscriptionRow: View {
    @ObservedObject var store: SpaceStore
    let account: Account
    let title: String
    var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderMark(provider: account.provider)
                Text(title).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if !account.plan.isEmpty {
                    Text(account.plan.capitalized).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }
            let windows = expanded ? account.allWindows : account.mainWindows
            ForEach(windows) { window in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        LengthTag(window: window)
                        Text(window.label).font(.footnote).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(String(localized: "\(Format.percent(window.remainingPercent)) left")).font(.footnote.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(window.level == .normal ? Color.primary : window.level.color)
                    }
                    LeftBar(remainingPercent: window.remainingPercent, color: window.level.color)
                    Text(window.resetLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let balances = account.usage?.balances, !balances.isEmpty, account.usage?.issue != "AUTH_REQUIRED" {
                ForEach(Array(balances.enumerated()), id: \.offset) { _, balance in
                    HStack {
                        Text(Self.balanceName(balance.kind)).font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Text(balance.text).font(.footnote.weight(balance.kind == "total" ? .semibold : .regular)).monospacedDigit()
                            .foregroundStyle(balance.kind == "total" && balance.isEmpty ? QuotaWindow.Level.critical.color : Color.primary)
                    }
                }
            }
            if account.allWindows.isEmpty && (account.usage?.balances ?? []).isEmpty {
                Text(account.usage?.issue == "AUTH_REQUIRED" ? String(localized: "Sign in again from the panel") : String(localized: "No quota reading yet"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 2) { ForEach(facts, id: \.self) { Text($0).lineLimit(2) } }
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(account.usage?.stale == true ? 0.6 : 1)
    }

    var facts: [String] {
        var out: [String] = []
        let who = [account.email.isEmpty ? nil : account.email, account.server ? String(localized: "Account of the server") : nil].compactMap { $0 }
        if !who.isEmpty { out.append(who.joined(separator: " · ")) }
        let agents = store.agentNames(account)
        out.append(agents.isEmpty ? String(localized: "No agent uses it") : String(localized: "Used by \(agents.joined(separator: ", "))"))
        if let at = account.usage?.fetchedAt { out.append(String(localized: "Read \(Format.ago(at))") + (account.usage?.stale == true ? " · " + String(localized: "out of date") : "")) }
        if account.usage?.issue == "AUTH_REQUIRED", !account.allWindows.isEmpty { out.append(String(localized: "Sign in again from the panel")) }
        return out
    }

    static func balanceName(_ kind: String) -> String {
        switch kind {
        case "total": return String(localized: "Total")
        case "granted": return String(localized: "Granted")
        case "topped-up": return String(localized: "Topped up")
        default: return kind.capitalized
        }
    }
}
