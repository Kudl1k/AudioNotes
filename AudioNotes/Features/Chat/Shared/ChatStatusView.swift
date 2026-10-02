import SwiftUI

struct ChatThinkingIndicator: View {
    let phase: String
    let startedAt: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AudioNotes").font(.caption.bold()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(phase).font(.callout).foregroundStyle(.secondary)
            }
            if let startedAt {
                OperationElapsedTimeView(startedAt: startedAt)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine).accessibilityIdentifier("chat.thinking")
    }
}

struct ChatStreamingIndicator<Content: View>: View {
    var startedAt: Date? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("AudioNotes").font(.caption.bold()).foregroundStyle(.secondary)
                ProgressView().controlSize(.mini).accessibilityLabel("Generating answer")
                Spacer(minLength: 0)
                if let startedAt { OperationElapsedTimeView(startedAt: startedAt) }
            }
            content()
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ChatErrorView: View {
    let error: String
    let canRetry: Bool
    let onRetry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            if canRetry {
                Button("Retry", action: onRetry).accessibilityLabel("Retry answer").accessibilityIdentifier("chat.retry")
            }
            SettingsLink { Text("Choose Chat Provider…") }
                .accessibilityLabel("Chat provider and model settings").accessibilityIdentifier("chat.settings")
        }.buttonStyle(.bordered).controlSize(.small).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ChatEmptyState<Actions: View>: View {
    let title: String
    let description: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(description).font(.callout).foregroundStyle(.secondary)
            actions()
        }.padding(.vertical, 16)
    }
}

/// Keep one lazy-list child identity while waiting changes into a streamed answer.
struct ChatActiveResponse<Content: View>: View {
    let isStreaming: Bool
    let phase: String
    let startedAt: Date?
    @ViewBuilder var content: () -> Content
    var body: some View {
        if isStreaming {
            ChatStreamingIndicator(startedAt: startedAt, content: content)
        } else {
            ChatThinkingIndicator(phase: phase, startedAt: startedAt)
        }
    }
}
