#if DEBUG
import SwiftData
import SwiftUI

// Previews for reusable, high-value surfaces. They use PreviewFixtures only: no providers, Keychain,
// network, preferences or production storage. See docs/ACCESSIBILITY_AND_QA.md.

// MARK: Chat

@MainActor private func previewRow<Content: View>(_ role: ChatRole, interrupted: Bool = false, canRegenerate: Bool = false,
                        @ViewBuilder content: @escaping () -> Content) -> some View {
    let message = ChatMessage(role: role, text: "", status: interrupted ? .interrupted : .completed)
    return ChatMessageRow(presentation: ChatMessagePresentation(message), canRegenerate: canRegenerate,
        onCopy: {}, onRegenerate: {}, content: content)
}

#Preview("Chat message rows") {
    ScrollView {
        VStack(spacing: 14) {
            previewRow(.user) { Text("What did we decide about the release?").textSelection(.enabled).font(.callout) }
            previewRow(.assistant, canRegenerate: true) {
                AssistantMessageView(markdown: PreviewFixtures.planningMarkdown, references: [])
                SourceReferenceChips(references: PreviewFixtures.citations) { _ in }
            }
            previewRow(.assistant, interrupted: true) {
                AssistantMessageView(markdown: "The beta ships in **March**, but the answer was cut off befo", references: [])
            }
        }.padding()
    }
    .frame(width: 520, height: 640)
    .modelContainer(PreviewFixtures.container())
}

#Preview("Chat status and empty state") {
    VStack(spacing: 14) {
        ChatThinkingIndicator(phase: "Searching project material…", startedAt: .now.addingTimeInterval(-12))
        ChatStreamingIndicator(startedAt: .now.addingTimeInterval(-31)) {
            AssistantMessageView(markdown: "The team agreed to ship the beta in **March**, and", references: [])
        }
        ChatErrorView(error: "The provider did not respond. Check your connection and try again.", canRetry: true, onRetry: {})
        ChatEmptyState(title: "Chat about this recording", description: "Answers use your selected ready sources with clickable references.") {
            Text("Suggested questions").font(.caption.bold()).foregroundStyle(.secondary)
            Button("Summarize the key decisions") {}.buttonStyle(.link)
        }
    }.padding().frame(width: 460)
}

private struct ComposerPreview: View {
    @State var text: String
    var isGenerating = false
    @State private var focus = 0
    var body: some View {
        ChatComposer(text: $text, focusRequest: $focus, placeholder: "Ask about this recording…",
            canSend: !text.isEmpty, isGenerating: isGenerating, onSend: {}, onStop: {}).padding().frame(width: 460)
    }
}

#Preview("Chat composer") {
    VStack(spacing: 8) {
        ComposerPreview(text: "")
        ComposerPreview(text: "What were the action items?")
        ComposerPreview(text: "A long multi-line draft\nwith a second line\nand a third line", isGenerating: true)
    }
}

// MARK: Progress and errors

#Preview("Operation progress") {
    VStack(alignment: .leading, spacing: 18) {
        OperationProgressView(title: "Preparing audio…", startedAt: .now.addingTimeInterval(-5), cancel: {})
        OperationProgressView(title: "Transcribing audio…", status: "Part 2 of 3 · 1 completed",
            progress: OperationProgressValue(fraction: 0.33), startedAt: .now.addingTimeInterval(-96),
            estimatedRemaining: 190, cancel: {})
        OperationProgressView(title: "Importing source…", status: "Page 12 of 40",
            progress: OperationProgressValue(completed: 12, total: 40), startedAt: .now.addingTimeInterval(-18), cancel: {})
        OperationProgressView(title: "Downloading Whisper model…", status: "412 MB / 1.5 GB",
            progress: OperationProgressValue(fraction: 0.27), startedAt: .now.addingTimeInterval(-64), cancel: {})
        InlineErrorLabel("Download or model operation failed: the file could not be verified.", font: .body)
    }.padding().frame(width: 460)
}

// MARK: Project workspace

private struct WorkspacePreview: View {
    let populated: Bool
    @State private var container = PreviewFixtures.container()
    var body: some View {
        WorkspaceHost(populated: populated).modelContainer(container)
    }
}

private struct WorkspaceHost: View {
    let populated: Bool
    @Environment(\.modelContext) private var context
    @State private var project: Project?
    @State private var queue = ProjectImportQueue(storage: PreviewFixtures.storage)
    @State private var library = LibraryViewModel()
    var body: some View {
        Group {
            if let project {
                ProjectWorkspaceView(project: project, projects: [project], queue: queue, library: library,
                    llmResolver: FixedLLMProviderResolver(provider: MockLLMProvider()),
                    openRecording: { _ in }, moveRecordingIDs: { _, _ in }, importFiles: {})
            } else { ProgressView() }
        }
        .task { if project == nil { project = PreviewFixtures.project(populated: populated, in: context) } }
    }
}

#Preview("Project workspace · populated") { WorkspacePreview(populated: true).frame(width: 760, height: 560) }
#Preview("Project workspace · empty") { WorkspacePreview(populated: false).frame(width: 760, height: 480) }
#Preview("Project workspace · minimum width") { WorkspacePreview(populated: true).frame(width: 520, height: 420) }

// MARK: Transcript

#Preview("Transcript") {
    TranscriptView(transcript: try? PerformanceFixtures.recording(.small).transcript, seek: { _ in })
        .frame(width: 640, height: 420)
}
#endif
