import AppKit
import CoraKit
import SwiftUI

extension Color {
    /// `#f2a93b` from Cora's agent colors.
    init(hex: String, fallback: Color = .orange) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let value = UInt32(clean, radix: 16) else { self = fallback; return }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}

extension QuotaWindow.Level {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

struct PreviewFlag: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isStaticPreview: Bool { get { self[PreviewFlag.self] } set { self[PreviewFlag.self] = newValue } }
}

/// The agent's picture from the space, or its initial on its color. A ring in its color while it works.
struct AgentAvatar: View {
    let agent: Agent
    let url: URL?
    var size: CGFloat = 28
    var ring = true
    @Environment(\.isStaticPreview) private var isStaticPreview

    var body: some View {
        let tint = Color(hex: agent.color)
        ZStack {
            Circle().fill(tint.opacity(0.22))
            Text(String(agent.name.prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tint)
            if let url, !isStaticPreview {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { Color.clear }
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if ring && agent.state == .working {
                Circle().strokeBorder(tint, lineWidth: 2).padding(-3)
            }
        }
        .opacity(agent.state == .off ? 0.45 : 1)
        .accessibilityHidden(true)
    }
}

struct StateBadge: View {
    let state: Agent.State

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    var label: String {
        switch state {
        case .working: return String(localized: "Working")
        case .listening: return String(localized: "Listening")
        case .idle: return String(localized: "Idle")
        case .off: return String(localized: "Off")
        }
    }

    var color: Color {
        switch state {
        case .working: return .green
        case .listening: return .blue
        case .idle: return Color.secondary.opacity(0.6)
        case .off: return Color.secondary.opacity(0.3)
        }
    }
}

struct UsageBar: View {
    let usedPercent: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(color)
                    .frame(width: usedPercent <= 0 ? 0 : max(5, proxy.size.width * min(1, usedPercent / 100)))
            }
        }
        .frame(height: 5)
    }
}

extension QuotaWindow {
    /// `Weekly`, `5-hour session`: what the window is, for the reset line.
    var label: String {
        let base: String
        switch kind {
        case .session: base = String(localized: "5-hour session")
        case .weekly: base = String(localized: "Weekly")
        case .monthly: base = String(localized: "Monthly")
        case .custom: base = minutes.map { String(localized: "\($0 / 60)-hour window") } ?? String(localized: "Limit")
        }
        return group.isEmpty ? base : "\(base) · \(group)"
    }
}

/// One subscription: provider mark and name, then its account-wide windows, one line each with its length (`5h`, `7d`),
/// reset countdown, what is left and the percent; the shorter window on the name's line, the longer one under it. A
/// pay-as-you-go account shows its balance. The mark stays one line tall. A click opens every limit, balance and
/// detail of the subscription.
struct SubscriptionRow: View {
    let account: Account
    let title: String
    var pinned = false
    var expanded = false
    var agents: [String] = []
    var onPin: (() -> Void)?
    var onToggle: (() -> Void)?

    static let lineHeight: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                ProviderMark(provider: account.provider, size: 14).frame(height: Self.lineHeight)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer(minLength: 6)
                        firstLine
                    }
                    .frame(height: Self.lineHeight)
                    if windows.count > 1 {
                        HStack(spacing: 0) { Spacer(minLength: 0); WindowFigures(window: windows[1]) }.frame(height: Self.lineHeight - 2)
                    }
                }
                pin.frame(height: Self.lineHeight)
            }
            if expanded {
                SubscriptionDetail(account: account, agents: agents).padding(.leading, 22).padding(.trailing, 4).padding(.top, 6).padding(.bottom, 2)
            }
        }
        .opacity(account.usage?.stale == true && !expanded ? 0.6 : 1)
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { onToggle?() } }
        .help(expanded ? String(localized: "Hide the details") : String(localized: "Show every limit of this subscription"))
        .accessibilityAddTraits(.isButton)
    }

    var windows: [QuotaWindow] { account.mainWindows }

    @ViewBuilder var firstLine: some View {
        if let window = windows.first {
            WindowFigures(window: window)
        } else if let balance = account.balance {
            Text("Balance").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Text(balance.text).font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(1)
                .foregroundStyle(balance.isEmpty ? QuotaWindow.Level.critical.color : Color.primary)
                .help(String(localized: "Pay-as-you-go: what is left on the account"))
        } else {
            Text(issue).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Text("–").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }

    @ViewBuilder var pin: some View {
        if let onPin {
            Button(action: onPin) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(pinned ? Color.accentColor : Color.secondary.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pinned ? String(localized: "Remove from the menu bar") : String(localized: "Show this subscription in the menu bar"))
            .accessibilityLabel(Text(pinned ? "Remove from the menu bar" : "Show this subscription in the menu bar"))
        }
    }

    /// Instead of the bar when there is no reading.
    var issue: String {
        switch account.usage?.issue ?? account.usage?.state ?? "" {
        case "AUTH_REQUIRED": return String(localized: "Sign in again")
        case "loading", "connecting": return String(localized: "Reading…")
        default: return String(localized: "No reading")
        }
    }
}

/// One window on one line: its length as a tag, when it resets, what is left, the percent. Fixed widths, so the
/// columns line up from one subscription to the next.
struct WindowFigures: View {
    let window: QuotaWindow

    var body: some View {
        HStack(spacing: 5) {
            Text(window.tag()).font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                .padding(.horizontal, 4).frame(minWidth: 26).frame(height: 15)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            Text(reset).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                .frame(width: 44, alignment: .trailing)
            LeftBar(remainingPercent: window.remainingPercent, color: window.level.color).frame(width: 40)
            Text(Format.percent(window.remainingPercent)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(window.level == .normal ? Color.primary : window.level.color)
                .frame(width: 34, alignment: .trailing)
        }
        .help(window.label + (window.resetsAt.map { " · " + String(localized: "Resets in \(Format.countdown(to: $0))") + " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
    }

    var reset: String { window.resetsAt.map { Format.countdown(to: $0) } ?? "" }
}

/// The subscription opened up: every window with its full name, the exact reset and what is used, model-scoped limits
/// included; every balance; plan, mailbox, the agents that run on it and when it was last read.
struct SubscriptionDetail: View {
    let account: Account
    let agents: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(account.allWindows) { window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(window.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(String(localized: "\(Format.percent(window.remainingPercent)) left")).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(window.level == .normal ? Color.primary : window.level.color)
                    }
                    LeftBar(remainingPercent: window.remainingPercent, color: window.level.color)
                    HStack(spacing: 6) {
                        Text(resetLine(window)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(String(localized: "\(Format.percent(window.usedPercent)) used")).monospacedDigit()
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let balances = account.usage?.balances, !balances.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(balances.enumerated()), id: \.offset) { _, balance in
                        HStack {
                            Text(Self.balanceName(balance.kind)).font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Text(balance.text).font(.system(size: 11, weight: balance.kind == "total" ? .semibold : .regular)).monospacedDigit()
                                .foregroundStyle(balance.kind == "total" && balance.isEmpty ? QuotaWindow.Level.critical.color : Color.primary)
                        }
                    }
                }
            }
            if account.allWindows.isEmpty && (account.usage?.balances ?? []).isEmpty {
                Text("No quota reading yet").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(facts, id: \.self) { Text($0).lineLimit(2) }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    func resetLine(_ window: QuotaWindow) -> String {
        guard let reset = window.resetsAt else { return String(localized: "No reset time") }
        if reset <= Date() { return String(localized: "Reset due: waiting for a new reading") }
        return String(localized: "Resets in \(Format.countdown(to: reset))") + " · " + reset.formatted(date: .abbreviated, time: .shortened)
    }

    var facts: [String] {
        var out: [String] = []
        let who = [account.plan.isEmpty ? nil : account.plan.capitalized, account.email.isEmpty ? nil : account.email, account.server ? String(localized: "Account of the server") : nil].compactMap { $0 }
        if !who.isEmpty { out.append(who.joined(separator: " · ")) }
        out.append(agents.isEmpty ? String(localized: "No agent uses it") : String(localized: "Used by \(agents.joined(separator: ", "))"))
        if let at = account.usage?.fetchedAt { out.append(String(localized: "Read \(Format.ago(at))") + (account.usage?.stale == true ? " · " + String(localized: "out of date") : "")) }
        if account.usage?.issue == "AUTH_REQUIRED" { out.append(String(localized: "Sign in again from the panel")) }
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

/// What is left of a window: full when untouched, empty at the limit.
struct LeftBar: View {
    let remainingPercent: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(color)
                    .frame(width: remainingPercent <= 0 ? 0 : max(5, proxy.size.width * min(1, remainingPercent / 100)))
            }
        }
        .frame(height: 5)
    }
}

/// The provider's mark in the text color, or a neutral dot when the app has no mark for it.
struct ProviderMark: View {
    let provider: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = ProviderIcon.template(provider) {
                Image(nsImage: image).resizable().renderingMode(.template).interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "circle.dashed").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(.primary)
        .accessibilityLabel(Text(Providers.name(provider)))
    }
}

/// The Tokens page of the window: the subscriptions with their pin, then how many tokens each agent used in the
/// last 7 days. The popover shows the two halves in their own tabs.
struct TokensSummary: View {
    @ObservedObject var store: SpaceStore
    let snapshot: Snapshot
    var openAgent: (String) -> Void = { _ in }
    var showSubscriptions = true
    var showTokens = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showSubscriptions { subscriptions }
            if showTokens { tokens }
        }
    }

    var subscriptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(Text("Subscriptions"), trailing: nil)
            if snapshot.accounts.isEmpty {
                Text("No subscription is linked to your agents.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 2)
            }
            if !snapshot.accounts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider().padding(.leading, 30) }
                        SubscriptionRow(account: account, title: snapshot.title(of: account), pinned: store.isPinned(account), expanded: store.expanded.contains(account.id),
                                        agents: account.agentIds.compactMap { snapshot.agent($0)?.name },
                                        onPin: { store.togglePin(account) },
                                        onToggle: { store.toggleExpanded(account) })
                    }
                }
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                Text("Click a subscription for every limit. Pinned ones appear in the menu bar.").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 2)
            }
        }
    }

    var tokens: some View {
        VStack(alignment: .leading, spacing: 6) {
            let agents = snapshot.agents.filter { $0.usage.week.total > 0 }.sorted { $0.usage.week.total > $1.usage.week.total }
            let peak = max(1, agents.first?.usage.week.total ?? 1)
            heading(Text("Tokens, last 7 days"), trailing: Format.tokens(snapshot.agents.map(\.usage.week.total).reduce(0, +)))
            if agents.isEmpty {
                Text("No tokens used in the last 7 days.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 2)
            }
            ForEach(agents) { agent in
                Button { openAgent(agent.id) } label: {
                    HStack(spacing: 10) {
                        AgentAvatar(agent: agent, url: store.avatarURL(agent), size: 20)
                        Text(agent.name).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 90, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule().fill(Color(hex: agent.color, fallback: .accentColor).opacity(0.8))
                                .frame(width: max(4, proxy.size.width * CGFloat(agent.usage.week.total) / CGFloat(peak)), height: 5)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 12)
                        Text(Format.tokens(agent.usage.week.total)).font(.system(size: 12)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    func heading(_ title: Text, trailing: String?) -> some View {
        HStack {
            title.font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .padding(.horizontal, 2)
    }
}

/// One reasoning step: a thought, a tool call, text the agent wrote, a note from Cora.
struct StepRow: View {
    let step: Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(tint).frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                switch step.kind {
                case .tool:
                    Text(step.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    if !step.args.isEmpty && step.args != "{}" {
                        Text(step.args).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                    }
                    if !step.result.isEmpty {
                        Text(step.result).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                    }
                case .thinking:
                    Text(step.text).font(.system(size: 12)).italic().foregroundStyle(.secondary).textSelection(.enabled)
                default:
                    Text(step.text).font(.system(size: 12)).foregroundStyle(step.kind == .note ? .secondary : .primary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if let at = step.at {
                Text(at.formatted(date: .omitted, time: .standard)).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 3)
    }

    var symbol: String {
        switch step.kind {
        case .thinking: return "brain"
        case .tool: return "wrench.and.screwdriver"
        case .text: return "text.bubble"
        case .note: return "info.circle"
        case .other: return "circle"
        }
    }

    var tint: Color {
        switch step.kind {
        case .thinking: return .purple
        case .tool: return .blue
        case .text: return .green
        default: return .secondary
        }
    }
}

/// Each provider's mark, black on clear, drawn in the menu bar's text color.
enum ProviderIcon {
    static var cache: [String: NSImage] = [:]

    static func template(_ provider: String) -> NSImage? {
        if let image = cache[provider] { return image }
        guard let url = Bundle.main.url(forResource: provider, withExtension: "pdf", subdirectory: "ProviderIcons"), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[provider] = image
        return image
    }

    /// Tinted when drawn, so it follows a light or dark menu bar like the text beside it.
    static func tinted(_ provider: String, color: NSColor, size: CGFloat) -> NSImage? {
        guard let base = template(provider) else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.accessibilityDescription = Providers.name(provider)
        return image
    }
}

/// What the menu bar shows next to the Cora icon: each pinned subscription as its provider's icon and what is left, the
/// percent in orange or red near the limit. A subscription with two limits stacks them, each with its length: `5h 64%`
/// above `7d 80%`; subscriptions of one provider stand side by side under a single icon.
enum MenuBarTitle {
    struct Line: Hashable { var tag: String; var value: String; var level: QuotaWindow.Level? }
    struct Part: Hashable {
        var text: String; var level: QuotaWindow.Level?; var provider: String?; var title: String
        var lines: [Line] = []
    }

    @MainActor static func parts(_ store: SpaceStore) -> [Part] {
        guard let snapshot = store.snapshot else { return [] }
        return snapshot.pinned(store.pins).map { pin in
            let lines = pin.windows.count > 1 ? pin.windows.map { Line(tag: $0.tag(), value: Format.percent($0.remainingPercent), level: $0.level) } : []
            return Part(text: pin.value, level: pin.level, provider: pin.provider, title: pin.title, lines: lines)
        }
    }

    static func nsColor(_ level: QuotaWindow.Level?) -> NSColor {
        switch level {
        case .critical?: return .systemRed
        case .warning?: return .systemOrange
        default: return .labelColor
        }
    }

    /// The parts in the order of the space, those of one provider together under a single icon.
    static func groups(_ parts: [Part]) -> [[Part]] {
        var groups: [[Part]] = []
        for part in parts {
            if let provider = part.provider, let index = groups.firstIndex(where: { $0.first?.provider == provider }) {
                groups[index].append(part)
            } else {
                groups.append([part])
            }
        }
        return groups
    }

    static func attributed(_ parts: [Part]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for (index, group) in groups(parts).enumerated() {
            guard let first = group.first else { continue }
            out.append(NSAttributedString(string: index == 0 ? " " : "   ", attributes: [.font: font]))
            if let provider = first.provider {
                if let icon = ProviderIcon.tinted(provider, color: .labelColor, size: 13) {
                    let attachment = NSTextAttachment()
                    attachment.image = icon
                    attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
                    out.append(NSAttributedString(attachment: attachment))
                    out.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
                } else {
                    out.append(NSAttributedString(string: first.title + " ", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
                }
            }
            if group.count == 1 && first.lines.isEmpty {
                out.append(NSAttributedString(string: first.text, attributes: [.font: font, .foregroundColor: nsColor(first.level)]))
            } else {
                let attachment = NSTextAttachment()
                let column = stacked(group)
                attachment.image = column
                attachment.bounds = NSRect(x: 0, y: -6, width: column.size.width, height: column.size.height)
                out.append(NSAttributedString(attachment: attachment))
            }
        }
        return out
    }

    /// The readings of one provider in small type: one column per subscription, side by side; in each column its
    /// limits one above the other (`5h 64%` over `7d 80%`), or its single figure in the middle. Drawn when shown, so
    /// the colors follow a light or dark menu bar.
    static func stacked(_ group: [Part]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let tagFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        let lineHeight: CGFloat = 9.5
        let gap: CGFloat = 5
        func columnLines(_ part: Part) -> [Line] { part.lines.isEmpty ? [Line(tag: "", value: part.text, level: part.level)] : part.lines }
        func size(_ text: String, _ font: NSFont) -> CGFloat { text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        // Subscriptions with a single figure each share one column, as before; with two limits each gets its own.
        let single = group.allSatisfy { $0.lines.isEmpty }
        let lineSets = single ? [group.map { Line(tag: "", value: $0.text, level: $0.level) }] : group.map(columnLines)
        let columns = lineSets.map { lines -> (lines: [Line], tagWidth: CGFloat, valueWidth: CGFloat) in
            return (lines, lines.map { size($0.tag, tagFont) }.max() ?? 0, lines.map { size($0.value, font) }.max() ?? 0)
        }
        let widths = columns.map { $0.tagWidth + ($0.tagWidth > 0 ? 2 : 0) + $0.valueWidth }
        let rows = columns.map(\.lines.count).max() ?? 1
        let width = widths.reduce(0, +) + gap * CGFloat(max(0, columns.count - 1))
        let height = lineHeight * CGFloat(rows)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            var x: CGFloat = 0
            for (index, column) in columns.enumerated() {
                let top = (height - lineHeight * CGFloat(column.lines.count)) / 2
                for (row, line) in column.lines.enumerated() {
                    let y = top + CGFloat(row) * lineHeight
                    if !line.tag.isEmpty {
                        let tag = NSAttributedString(string: line.tag, attributes: [.font: tagFont, .foregroundColor: NSColor.secondaryLabelColor])
                        tag.draw(at: NSPoint(x: x, y: y + (lineHeight - tag.size().height) / 2 + 0.3))
                    }
                    let value = NSAttributedString(string: line.value, attributes: [.font: font, .foregroundColor: nsColor(line.level)])
                    let valueSize = value.size()
                    value.draw(at: NSPoint(x: x + widths[index] - valueSize.width, y: y + (lineHeight - valueSize.height) / 2))
                }
                x += widths[index] + gap
            }
            return true
        }
        image.accessibilityDescription = group.map { part in "\(part.title) " + columnLines(part).map { "\($0.tag) \($0.value)".trimmingCharacters(in: .whitespaces) }.joined(separator: ", ") }.joined(separator: "; ")
        return image
    }
}

/// The menu bar item for screenshots: an AppKit button with the same image and title the status item gets.
struct MenuBarStrip: View {
    @ObservedObject var store: SpaceStore

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            MenuBarButton(working: store.snapshot?.working.count ?? 0, title: MenuBarTitle.attributed(MenuBarTitle.parts(store)))
                .fixedSize()
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
            Image(systemName: "wifi").font(.system(size: 13)).padding(.leading, 14).foregroundStyle(.secondary)
            Text("12:34").font(.system(size: 13)).padding(.leading, 12).padding(.trailing, 12).foregroundStyle(.secondary)
        }
        .frame(height: 26)
    }
}

struct MenuBarButton: NSViewRepresentable {
    let working: Int
    let title: NSAttributedString

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageLeading
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.image = CoraMark.image(working: working)
        button.attributedTitle = title
    }
}

/// The Cora mark for the menu bar: the app icon's sphere as a template image, with the number of working agents small
/// at its top right (nothing when nobody works).
enum CoraMark {
    static func image(working: Int) -> NSImage {
        let badge = working > 0 ? NSAttributedString(string: "\(working)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold), .foregroundColor: NSColor.black]) : nil
        let badgeWidth = badge.map { ceil($0.size().width) } ?? 0
        let width = badge == nil ? 17 : max(20, 15.2 + badgeWidth)
        let image = NSImage(size: NSSize(width: width, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: 1.75, y: 2.25, width: 13.5, height: 13.5))
            ring.lineWidth = 1.5
            ring.stroke()
            let seam = NSBezierPath()
            seam.move(to: NSPoint(x: 2.0, y: 10.6))
            seam.curve(to: NSPoint(x: 14.4, y: 6.4), controlPoint1: NSPoint(x: 6.0, y: 12.0), controlPoint2: NSPoint(x: 10.5, y: 10.0))
            seam.lineWidth = 1.3
            seam.lineCapStyle = .round
            seam.stroke()
            if let badge {
                // A knockout behind the number so it reads over the ring.
                let box = NSRect(x: width - badgeWidth - 1.6, y: -0.6, width: badgeWidth + 1.6, height: 10.2)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                badge.draw(at: NSPoint(x: width - badgeWidth - 0.8, y: -1.2))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Cora"
        return image
    }
}
