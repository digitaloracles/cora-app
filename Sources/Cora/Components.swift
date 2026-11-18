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
            if agent.state == .working {
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

/// One subscription on one line: provider mark and name, when its tightest window resets, what is left, the pin.
struct SubscriptionRow: View {
    let account: Account
    let title: String
    var pinned = false
    var onPin: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            ProviderMark(provider: account.provider, size: 14)
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if let window = account.tightestWindow {
                if let reset = window.resetsAt {
                    Text(Format.countdown(to: reset)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                        .help("\(window.label) · " + String(localized: "Resets in \(Format.countdown(to: reset))") + " · " + reset.formatted(date: .abbreviated, time: .shortened))
                }
                LeftBar(remainingPercent: window.remainingPercent, color: window.level.color).frame(width: 56)
                Text(Format.percent(window.remainingPercent)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(window.level == .normal ? Color.primary : window.level.color)
                    .frame(width: 36, alignment: .trailing)
            } else {
                Text(issue).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Text("–").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
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
        .opacity(account.usage?.stale == true ? 0.6 : 1)
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 5)
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

/// The Tokens page, the same in the popover and in the window: the subscriptions with their pin, then how many
/// tokens each agent used in the last 7 days.
struct TokensSummary: View {
    @ObservedObject var store: SpaceStore
    let snapshot: Snapshot
    var openAgent: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                heading(Text("Subscriptions"), trailing: nil)
                if snapshot.accounts.isEmpty {
                    Text("No subscription is linked to your agents.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 2)
                }
                if !snapshot.accounts.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.accounts.enumerated()), id: \.element.id) { index, account in
                            if index > 0 { Divider().padding(.leading, 30) }
                            SubscriptionRow(account: account, title: snapshot.title(of: account), pinned: store.isPinned(account), onPin: { store.togglePin(account) })
                        }
                    }
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                    Text("Pinned ones appear in the menu bar.").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.horizontal, 2)
                }
            }
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

/// What the menu bar shows next to the Cora icon: the working agents, then each pinned subscription as its provider's
/// icon and what is left, the percent in orange or red near the limit.
enum MenuBarTitle {
    struct Part: Hashable { var text: String; var level: QuotaWindow.Level?; var provider: String?; var title: String }

    @MainActor static func parts(_ store: SpaceStore) -> [Part] {
        guard let snapshot = store.snapshot else { return [] }
        var parts: [Part] = []
        parts += snapshot.pinned(store.pins).map { Part(text: $0.value, level: $0.window?.level, provider: $0.provider, title: $0.title) }
        return parts
    }

    static func nsColor(_ level: QuotaWindow.Level?) -> NSColor {
        switch level {
        case .critical?: return .systemRed
        case .warning?: return .systemOrange
        default: return .labelColor
        }
    }

    static func attributed(_ parts: [Part]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for (index, part) in parts.enumerated() {
            out.append(NSAttributedString(string: index == 0 ? " " : "   ", attributes: [.font: font]))
            if let provider = part.provider {
                if let icon = ProviderIcon.tinted(provider, color: .labelColor, size: 13) {
                    let attachment = NSTextAttachment()
                    attachment.image = icon
                    attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
                    out.append(NSAttributedString(attachment: attachment))
                    out.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
                } else {
                    out.append(NSAttributedString(string: part.title + " ", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
                }
            }
            out.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: nsColor(part.level)]))
        }
        return out
    }
}

/// The menu bar item for screenshots: an AppKit button with the same image and title the status item gets.
struct MenuBarStrip: View {
    @ObservedObject var store: SpaceStore

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            MenuBarButton(working: !(store.snapshot?.working.isEmpty ?? true), title: MenuBarTitle.attributed(MenuBarTitle.parts(store)))
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
    let working: Bool
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

/// The Cora mark for the menu bar: the app icon's sphere as a template image; a dot when agents are working.
enum CoraMark {
    static func image(working: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: 2.25, y: 2.25, width: 13.5, height: 13.5))
            ring.lineWidth = 1.5
            ring.stroke()
            let seam = NSBezierPath()
            seam.move(to: NSPoint(x: 2.6, y: 10.4))
            seam.curve(to: NSPoint(x: 14.6, y: 5.0), controlPoint1: NSPoint(x: 6.5, y: 13.2), controlPoint2: NSPoint(x: 11.5, y: 10.6))
            seam.lineWidth = 1.5
            seam.lineCapStyle = .round
            seam.stroke()
            if working { NSBezierPath(ovalIn: NSRect(x: 13.0, y: 0.5, width: 4.5, height: 4.5)).fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Cora"
        return image
    }
}
