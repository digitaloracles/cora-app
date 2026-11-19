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

extension QuotaWindow {
    /// `Weekly`, `5-hour session`: what the window is.
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

    var resetLine: String {
        guard let reset = resetsAt else { return String(localized: "No reset time") }
        if reset <= Date() { return String(localized: "Reset due: waiting for a new reading") }
        return String(localized: "Resets in \(Format.countdown(to: reset))") + " · " + Self.when(reset)
    }

    /// `17:22` today, `Sat 17:22` within a week, `Dec 17` further away.
    static func when(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if date.timeIntervalSinceNow < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated).hour().minute()) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The agent's picture from the space, or its initial on its color. A ring in its color while it works.
struct AgentAvatar: View {
    let agent: Agent
    let url: URL?
    var size: CGFloat = 36

    var body: some View {
        let tint = Color(hex: agent.color)
        ZStack {
            Circle().fill(tint.opacity(0.22))
            Text(String(agent.name.prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tint)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { Color.clear }
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if agent.state == .working { Circle().strokeBorder(tint, lineWidth: 2).padding(-3) }
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
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
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

/// What is left of a window: full when untouched, empty at the limit.
struct LeftBar: View {
    let remainingPercent: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(color)
                    .frame(width: remainingPercent <= 0 ? 0 : max(height, proxy.size.width * min(1, remainingPercent / 100)))
            }
        }
        .frame(height: height)
    }
}

/// The provider's mark in the text color, or a neutral dot when the app has no mark for it.
struct ProviderMark: View {
    let provider: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if UIImage(named: "provider-\(provider)") != nil {
                Image("provider-\(provider)").resizable().renderingMode(.template).scaledToFit()
            } else {
                Image(systemName: "circle.dashed").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(.primary)
        .accessibilityLabel(Text(Providers.name(provider)))
    }
}

/// `5h`, `7d`: the window's length as a small tag.
struct LengthTag: View {
    let window: QuotaWindow

    var body: some View {
        Text(window.tag())
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .frame(minWidth: 30)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct StepRow: View {
    let step: Step

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                switch step.kind {
                case .tool:
                    Text(step.name).font(.system(.footnote, design: .monospaced).weight(.semibold))
                    if !step.args.isEmpty && step.args != "{}" {
                        Text(step.args).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4)
                    }
                    if !step.result.isEmpty {
                        Text(step.result).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(6)
                    }
                case .thinking:
                    Text(step.text).font(.footnote).italic().foregroundStyle(.secondary)
                default:
                    Text(step.text).font(.footnote).foregroundStyle(step.kind == .note ? .secondary : .primary)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            if let at = step.at {
                Text(at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
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

/// A short line for an empty or failed list.
struct Placeholder: View {
    let text: String
    var body: some View { Text(text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
}

/// The snapshot, or its progress and error, around a screen of the space.
struct Loaded<Content: View>: View {
    @ObservedObject var store: SpaceStore
    @ViewBuilder var content: (Snapshot) -> Content

    var body: some View {
        if let snapshot = store.snapshot {
            content(snapshot)
        } else if case .failed(let message) = store.phase {
            ContentUnavailableView {
                Label("Cannot read the space", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await store.refresh() } }
            }
        } else {
            ProgressView("Reading the space…")
        }
    }
}
