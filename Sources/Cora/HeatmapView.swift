import CoraKit
import SwiftUI

/// The panel's heatmap colors: Cora's amber in four steps over an empty square.
enum HeatPalette {
    static let amber = Color(red: 0xF2 / 255, green: 0xA9 / 255, blue: 0x3B / 255)

    static func fill(_ level: Int) -> Color {
        switch level {
        case 1: return amber.opacity(0.22)
        case 2: return amber.opacity(0.45)
        case 3: return amber.opacity(0.7)
        case 4: return amber
        default: return Color.primary.opacity(0.08)
        }
    }
}

/// The scale, said once for the whole page.
struct HeatLegend: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("less").padding(.trailing, 2)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(HeatPalette.fill(level)).frame(width: 9, height: 9)
            }
            Text("more").padding(.leading, 2)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary)
    }
}

/// One square per day from the first use to today, weeks as columns from Monday. It keeps its squares at a readable
/// size: a history wider than the space it has scrolls sideways and opens on the latest week.
struct TokenHeatmap: View {
    let map: Heatmap
    var cell: CGFloat = 13
    var label: String = ""
    @State private var hovered: String?

    private let gap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(range).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            ViewThatFits(in: .horizontal) {
                plot
                ScrollView(.horizontal, showsIndicators: false) { plot }.defaultScrollAnchor(.trailing)
            }
            Text(hovered ?? (label.isEmpty ? " " : label)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
    }

    var plot: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: gap) {
                ForEach(map.weeks.indices, id: \.self) { column in
                    Text(map.months[column].map { Self.months[$0] } ?? "")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        .fixedSize().frame(width: cell, alignment: .leading)
                }
            }
            HStack(alignment: .top, spacing: gap) {
                ForEach(map.weeks.indices, id: \.self) { column in
                    VStack(spacing: gap) {
                        ForEach(map.weeks[column]) { square in
                            if square.day == nil {
                                Color.clear.frame(width: cell, height: cell)
                            } else {
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(HeatPalette.fill(square.level))
                                    .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(hovered == text(square) ? 0.7 : 0), lineWidth: 1))
                                    .frame(width: cell, height: cell)
                                    .help(text(square))
                                    .onHover { inside in
                                        if inside { hovered = text(square) } else if hovered == text(square) { hovered = nil }
                                    }
                            }
                        }
                    }
                }
            }
        }
        .fixedSize()
        .padding(.trailing, 1)
    }

    func text(_ square: Heatmap.Cell) -> String {
        let when = square.date.map { Self.day.string(from: $0) } ?? ""
        guard square.tokens > 0 else { return String(localized: "\(when) · nothing") }
        let turns = square.turns == 1 ? String(localized: "1 turn") : String(localized: "\(square.turns) turns")
        return "\(when) · " + String(localized: "\(Format.tokens(square.tokens)) tokens") + " · \(turns)"
    }

    var range: String {
        guard let first = Heatmap.date(map.firstDay), let last = Heatmap.date(map.lastDay) else { return "" }
        return map.firstDay == map.lastDay ? Self.full.string(from: first) : "\(Self.full.string(from: first)) – \(Self.full.string(from: last))"
    }

    static let months: [String] = {
        let formatter = DateFormatter()
        formatter.locale = .current
        return (formatter.shortStandaloneMonthSymbols ?? formatter.shortMonthSymbols).map { $0.replacingOccurrences(of: ".", with: "") }
    }()

    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

    static let full: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .medium
        return formatter
    }()
}

/// The Tokens page's usage: everyone together, then one map per agent, as in the panel.
struct UsageHeatmaps: View {
    @ObservedObject var store: SpaceStore
    let snapshot: Snapshot
    /// The width the page gives it, to choose how many agents sit side by side.
    let width: CGFloat
    var openAgent: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                HeatLegend()
            }
            .padding(.horizontal, 2)
            if let history = store.usageHistory {
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("All together").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(String(localized: "\(Format.tokens(history.total())) tokens")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if let map = Heatmap(byDay: history.byDay(), today: history.today) {
                            TokenHeatmap(map: map, cell: width >= 700 ? 14 : 12, label: String(localized: "One square per day: point at one to see how much."))
                        } else {
                            empty
                        }
                    }
                }
                let agents = snapshot.agents.sorted { history.total(agentId: $0.id) > history.total(agentId: $1.id) }
                let columns = max(1, min(3, Int((width + 12) / 300)))
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(Array(stride(from: 0, to: agents.count, by: columns)), id: \.self) { start in
                        GridRow(alignment: .top) {
                            ForEach(start..<start + columns, id: \.self) { index in
                                if index < agents.count { agentCard(agents[index], history: history) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                            }
                        }
                    }
                }
            }
        }
    }

    func agentCard(_ agent: Agent, history: UsageHistory) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Button { openAgent(agent.id) } label: {
                    HStack(spacing: 8) {
                        AgentAvatar(agent: agent, url: store.avatarURL(agent), size: 22)
                        Text(agent.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(String(localized: "\(Format.tokens(history.total(agentId: agent.id))) tokens")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let map = Heatmap(byDay: history.byDay(agentId: agent.id), today: history.today) {
                    TokenHeatmap(map: map, cell: 11, label: Format.model(agent.model))
                } else {
                    empty
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var empty: some View {
        Label("Nothing used yet.", systemImage: "chart.bar.xaxis").font(.system(size: 11)).foregroundStyle(.secondary)
    }

    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}
