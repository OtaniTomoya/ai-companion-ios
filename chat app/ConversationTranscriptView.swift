import SwiftUI

struct ConversationTranscriptView: View {
    var messages: [ConversationMessage]
    var maxHeight: CGFloat? = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("会話ログ", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                Text("\(messages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if messages.isEmpty {
                ContentUnavailableView("ログはまだありません", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(messages) { message in
                                transcriptRow(message)
                                    .id(message.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: maxHeight)
                    .onChange(of: messages.last?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    private func transcriptRow(_ message: ConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(message.speaker.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint(for: message.speaker))
                Text(message.date, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(message.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(rowBackground(for: message.speaker), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tint(for speaker: ConversationMessage.Speaker) -> Color {
        switch speaker {
        case .user:
            .blue
        case .assistant:
            .purple
        case .system:
            .secondary
        }
    }

    private func rowBackground(for speaker: ConversationMessage.Speaker) -> Color {
        switch speaker {
        case .user:
            .blue.opacity(0.08)
        case .assistant:
            .purple.opacity(0.08)
        case .system:
            .gray.opacity(0.08)
        }
    }
}

#Preview {
    ConversationTranscriptView(messages: [
        ConversationMessage(speaker: .system, text: "接続しました。"),
        ConversationMessage(speaker: .user, text: "こんにちは。"),
        ConversationMessage(speaker: .assistant, text: "こんにちは。今日は何を話しましょうか。")
    ])
    .padding()
}
