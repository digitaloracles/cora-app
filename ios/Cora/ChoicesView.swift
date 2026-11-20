import CoraKit
import SwiftUI

/// A question an agent asked with answers to choose from. Tapping one answers it as the button in the chat would:
/// the agent hears it as the owner's word, and the chat shows the answer in place of its buttons.
struct ChoiceCard: View {
    @ObservedObject var store: SpaceStore
    let request: ChoiceRequest
    var showThread = true

    var body: some View {
        let agent = store.snapshot?.agent(request.agentId)
        let busy = store.answering.contains(request.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if let agent { AgentAvatar(agent: agent, url: store.avatarURL(agent), size: 30) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: String(localized: "%@ asks you"), request.agentName)).font(.subheadline.weight(.semibold))
                    HStack(spacing: 4) {
                        if showThread && !request.threadName.isEmpty { Text(request.threadName).lineLimit(1) }
                        if let at = request.askedAt { Text(Format.ago(at)) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if busy { ProgressView() }
            }
            Text(request.question).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            VStack(spacing: 8) {
                ForEach(Array(request.choices.enumerated()), id: \.offset) { index, label in
                    Button { Task { await store.answer(request, index: index) } } label: {
                        Text(label).font(.body.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(hex: request.color, fallback: .accentColor))
                }
            }
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }
}

/// The questions waiting for an answer at the top of a list, with what was just sent and why a tap failed.
struct ChoiceSection: View {
    @ObservedObject var store: SpaceStore
    let requests: [ChoiceRequest]
    var showThread = true

    var body: some View {
        if !requests.isEmpty || store.lastAnswer != nil || store.choiceError != nil {
            Section {
                if let error = store.choiceError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                }
                if let sent = store.lastAnswer {
                    Label(String(format: String(localized: "Sent to %@: %@"), sent.agentName, sent.answer), systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(.green)
                }
                ForEach(requests) { ChoiceCard(store: store, request: $0, showThread: showThread) }
            } header: {
                Text("Questions")
            }
        }
    }
}
