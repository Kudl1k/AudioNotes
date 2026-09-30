import SwiftUI

struct ChatInspectorView: View {
    let recording: Recording

    private var messages: [ChatMessage] {
        recording.chatSessions.sorted { $0.createdAt < $1.createdAt }
            .flatMap { $0.messages.sorted { $0.createdAt < $1.createdAt } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Chat", systemImage: "bubble.left.and.bubble.right")
                .font(.headline).padding()
            Divider()
            if messages.isEmpty {
                ContentUnavailableView("Chat is coming later", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Conversations about this recording will appear here when chat is available."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.role.rawValue.capitalized).font(.caption.bold())
                                Text(message.text).textSelection(.enabled)
                            }
                        }
                    }
                    .padding()
                }
            }
            Spacer(minLength: 0)
        }
    }
}
