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

struct WindowRow: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 12))
                Spacer()
                Text(Format.percent(window.remainingPercent)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Text("left").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            UsageBar(usedPercent: window.usedPercent, color: window.level.color)
            if let reset = window.resetsAt {
                Text("Resets in \(Format.countdown(to: reset))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(reset.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    var label: String {
        let base: String
        switch window.kind {
        case .session: base = String(localized: "5-hour session")
        case .weekly: base = String(localized: "Weekly")
        case .monthly: base = String(localized: "Monthly")
        case .custom: base = window.minutes.map { String(localized: "\($0 / 60)-hour window") } ?? String(localized: "Limit")
        }
        return window.group.isEmpty ? base : "\(base) · \(window.group)"
    }
}

/// One account the agents run on: its windows, and who uses it.
struct AccountCard: View {
    let account: Account
    let agents: [Agent]
    var pinned = false
    var onPin: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(Providers.name(account.provider)).font(.system(size: 13, weight: .semibold))
                if !account.plan.isEmpty {
                    Text(account.plan.capitalized).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                }
                Spacer()
                if account.server { Image(systemName: "server.rack").font(.system(size: 10)).foregroundStyle(.secondary).help(String(localized: "Account of the server")) }
                if let onPin {
                    Button(action: onPin) {
                        Label(pinned ? String(localized: "In the menu bar") : String(localized: "Pin"), systemImage: pinned ? "pin.fill" : "pin")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(pinned ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(pinned ? String(localized: "Remove from the menu bar") : String(localized: "Show this subscription in the menu bar"))
                }
            }
            if !account.email.isEmpty || !account.label.isEmpty {
                Text(account.email.isEmpty ? account.label : account.email).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            let windows = account.usage?.windows ?? []
            if windows.isEmpty {
                Label(issue, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(windows) { WindowRow(window: $0) }
                    .opacity(account.usage?.stale == true ? 0.55 : 1)
            }
            if !agents.isEmpty {
                Text("Used by \(agents.map(\.name).joined(separator: ", "))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(pinned ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1))
    }

    var issue: String {
        switch account.usage?.issue ?? account.usage?.state ?? "" {
        case "AUTH_REQUIRED": return String(localized: "Sign in again from the panel")
        case "loading", "connecting": return String(localized: "Reading the quota…")
        case "": return String(localized: "No quota reading yet")
        default: return String(localized: "Quota not available right now")
        }
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

/// What the menu bar shows next to the icon: the working agents, then each pinned subscription in its color.
enum MenuBarTitle {
    struct Part: Hashable { var text: String; var level: QuotaWindow.Level? }

    @MainActor static func parts(_ store: SpaceStore) -> [Part] {
        guard let snapshot = store.snapshot else { return [] }
        var parts: [Part] = []
        if !snapshot.working.isEmpty { parts.append(Part(text: "\(snapshot.working.count)", level: nil)) }
        parts += snapshot.pinned(store.pins).map { Part(text: $0.text, level: $0.window?.level) }
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
            out.append(NSAttributedString(string: index == 0 ? " " : "  ·  ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            out.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: nsColor(part.level)]))
        }
        return out
    }
}

/// The menu bar item drawn as SwiftUI, for screenshots: same icon, same parts, same colors.
struct MenuBarStrip: View {
    @ObservedObject var store: SpaceStore

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: (store.snapshot?.working.isEmpty ?? true) ? "person.2.wave.2" : "person.2.wave.2.fill").font(.system(size: 13))
                Text(AttributedString(MenuBarTitle.attributed(MenuBarTitle.parts(store))))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
            Image(systemName: "wifi").font(.system(size: 13)).padding(.leading, 14).foregroundStyle(.secondary)
            Text("12:34").font(.system(size: 13)).padding(.leading, 12).padding(.trailing, 12).foregroundStyle(.secondary)
        }
        .frame(height: 26)
    }
}
