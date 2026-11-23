import CoraKit
import SwiftUI

/// A question an agent asked with answers to choose from. Pressing one answers it as the button in the chat would:
/// the agent hears it as the owner's word, and the chat shows the answer in place of its buttons. The cross sets it aside.
struct ChoiceCard: View {
    @ObservedObject var store: SpaceStore
    let request: ChoiceRequest
    var compact = false

    var body: some View {
        let agent = store.snapshot?.agent(request.agentId)
        let tint = Color(hex: request.color, fallback: .accentColor)
        let busy = store.answering.contains(request.id)
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(alignment: .top, spacing: compact ? 8 : 10) {
                if let agent { AgentAvatar(agent: agent, url: store.avatarURL(agent), size: compact ? 24 : 28, ring: false) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: String(localized: "%@ asks you"), request.agentName)).font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 4) {
                        if !request.threadName.isEmpty { Text(request.threadName).lineLimit(1) }
                        if let at = request.askedAt { Text(Format.ago(at)) }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let url = URL(string: request.link), !request.link.isEmpty {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .font(.system(size: 12)).foregroundStyle(.secondary).help(String(localized: "Open the conversation"))
                }
                Button { Task { await store.dismiss(request) } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .help(String(localized: "Ignore this question")).accessibilityLabel(String(localized: "Ignore"))
                    .disabled(busy)
            }
            Text(request.question).font(.system(size: 13)).lineLimit(compact ? 6 : nil).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { buttons(busy: busy) }
                VStack(alignment: .leading, spacing: 6) { buttons(busy: busy, fill: true) }
            }
            .disabled(busy)
            if busy {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Sending…") }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 10 : 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.45), lineWidth: 1))
    }

    @ViewBuilder func buttons(busy: Bool, fill: Bool = false) -> some View {
        ForEach(Array(request.choices.enumerated()), id: \.offset) { index, label in
            Button { Task { await store.answer(request, index: index) } } label: {
                Text(label).lineLimit(1).frame(maxWidth: fill ? .infinity : nil)
            }
            .buttonStyle(.bordered).controlSize(compact ? .small : .regular)
        }
    }
}

/// The questions waiting for an answer, then what was just sent and why a press failed.
struct ChoiceList: View {
    @ObservedObject var store: SpaceStore
    let requests: [ChoiceRequest]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            if let error = store.choiceError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
            }
            if let sent = store.lastAnswer {
                Label(String(format: String(localized: "Sent to %@: %@"), sent.agentName, sent.answer), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.green).lineLimit(2)
            }
            ForEach(requests) { ChoiceCard(store: store, request: $0, compact: compact) }
        }
    }
}

/// The window's Questions page: every question the agents are waiting on, newest first.
struct QuestionsPage: View {
    @ObservedObject var store: SpaceStore
    let snapshot: Snapshot
    @Environment(\.isStaticPreview) private var isStaticPreview

    var body: some View {
        if isStaticPreview { content } else { ScrollView { content } }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Questions").font(.system(size: 20, weight: .semibold))
            if snapshot.requests.isEmpty && store.lastAnswer == nil && store.choiceError == nil {
                Text("No agent is waiting for an answer.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ChoiceList(store: store, requests: snapshot.requests)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
