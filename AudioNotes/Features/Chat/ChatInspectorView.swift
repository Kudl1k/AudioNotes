#if os(macOS)
import SwiftData
import SwiftUI

struct ChatInspectorView: View {
    let recording: Recording
    let resolver: any LLMProviderResolving
    var onSeek: ((TimeInterval) -> Void)?
    var onTranscribe: (() -> Void)?
    var onOpenSource: ((SourceReference) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var model: ChatViewModel
    @State private var showsUsage = false
    @State private var focusRequest = 0

    init(
        recording: Recording,
        resolver: any LLMProviderResolving,
        onSeek: ((TimeInterval) -> Void)? = nil,
        onTranscribe: (() -> Void)? = nil,
        onOpenSource: ((SourceReference) -> Void)? = nil,
        chatModel: ChatViewModel? = nil
    ) {
        self.recording = recording
        self.resolver = resolver
        self.onSeek = onSeek
        self.onTranscribe = onTranscribe
        self.onOpenSource = onOpenSource
        _model = State(initialValue: chatModel ?? ChatViewModel(recording: recording, resolver: resolver))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !model.hasReadySources {
                transcribePromptView
            } else {
                chatContentView
                Divider()
                composerView
            }
        }
        .sheet(isPresented: $showsUsage) { UsageCostView(recordingID: recording.id, feature: .chat) }
        .onAppear {
            let storage = SwiftDataChatRepository(context: modelContext)
            model.attachStorage(storage)
        }
        .confirmationDialog(
            "Clear Chat History?",
            isPresented: $model.confirmingClearChat,
            titleVisibility: .visible
        ) {
            Button("Clear Chat", role: .destructive) {
                model.clearChat()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the conversation history for this recording. Your transcript, summary, and audio file are not affected.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Label("Chat", systemImage: "bubble.left.and.bubble.right").font(.headline).accessibilityAddTraits(.isHeader)
                Text(model.providerDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            Spacer()
            Button("Chat usage", systemImage: "dollarsign.circle") { showsUsage = true }
                .labelStyle(.iconOnly).buttonStyle(.plain).help("Chat usage & cost").accessibilityIdentifier("chat.usage")

            if let session = model.session, !session.messages.isEmpty {
                Button {
                    model.confirmingClearChat = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear chat history").accessibilityLabel("Clear chat history").accessibilityIdentifier("chat.clear")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var transcribePromptView: some View {
        VStack(spacing: 16) {
            Spacer()
            ContentUnavailableView {
                Label("Ready Sources Required", systemImage: "waveform.badge.magnifyingglass")
            } description: {
                Text("Transcribe audio or add a PDF, image, or text document in Sources.")
            } actions: {
                if let onTranscribe {
                    Button("Transcribe Recording", action: onTranscribe)
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
        }
        .padding()
    }

    private var chatContentView: some View {
        ChatMessageList(scrollState: $model.scrollState, scrollPosition: $model.scrollPosition,
            messageCount: model.session?.messages.count ?? 0,
            latestMessageID: model.session?.orderedMessages.last?.id, activeResponseID: model.assistantMessageID, draft: model.streamingDraft,
            generationState: model.generationState, sentQuestionID: model.sentQuestionID) {
            if (model.session?.messages.isEmpty ?? true) && !model.isGenerating {
                emptyStateView
            }
            let messages = model.session?.orderedMessages ?? []
            ForEach(messages) { message in
                ChatMessageBubble(message: message, recording: recording,
                    canRegenerate: message.id == messages.last?.id && !model.isGenerating,
                    onSeek: onSeek, onOpenSource: onOpenSource, onRegenerate: model.regenerateLastAssistantResponse)
                    .id(message.id)
            }
            if model.isGenerating {
                ChatActiveResponse(isStreaming: model.generationState == .streaming,
                    phase: model.presentationPhase, startedAt: model.operationStartedAt) {
                    AssistantMessageView(
                        markdown: ChatContentNormalizer.clean(model.streamingDraft ?? "", references: model.streamingReferences, streaming: true, internalSegmentIDs: model.streamingSegmentIDs + model.sourceContextInternalIDs),
                        references: validatedReferences(model.streamingReferences), onSeek: onSeek)
                }.id("active-\(model.assistantMessageID)")
            }
            if let error = model.lastError {
                ChatErrorView(error: error, canRetry: model.canRetry, onRetry: model.retry)
            }
        }
    }

    private var emptyStateView: some View {
        ChatEmptyState(title: "Chat about this recording",
            description: "Answers use your selected ready sources with clickable references.") {
            Text("Suggested questions").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(ChatViewModel.suggestedPrompts, id: \.self) { prompt in
                Button(prompt) { model.sendSuggestedPrompt(prompt) }
                    .buttonStyle(.link).font(.caption).multilineTextAlignment(.leading)
            }
        }
    }

    private func validatedReferences(_ references: [TranscriptReference]) -> [TranscriptReference] {
        guard !references.isEmpty else { return [] }
        return TranscriptReferenceResolver().resolve(
            segmentIDs: references.compactMap { $0.segmentID?.uuidString },
            against: model.streamingSegments
        )
    }

    private var composerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            SourceSelectionView(recording: recording, selectedSourceIDs: $model.selectedSourceIDs,
                allowImageUpload: $model.allowImageUpload, supportsImages: model.supportsImageInput).disabled(model.isGenerating)
            if recording.sources.contains(where: { $0.type == .image && $0.isContextReady }) {
                Text(model.allowImageUpload && model.supportsImageInput ? model.imageInputDescription : "Images: local OCR text only")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ChatComposer(text: $model.inputText, focusRequest: $focusRequest,
                placeholder: "Ask about this recording…", canSend: model.canSend,
                isGenerating: model.isGenerating, onSend: model.sendMessage, onStop: model.stopGeneration)
        }
        .padding(12)
    }
}


/// Persistent rows do not observe token updates from the active response.
private struct ChatMessageBubble: View {
    let message: ChatMessage
    let recording: Recording
    let canRegenerate: Bool
    var onSeek: ((TimeInterval) -> Void)?
    var onOpenSource: ((SourceReference) -> Void)?
    let onRegenerate: () -> Void

    var body: some View {
        ChatMessageRow(presentation: ChatMessagePresentation(message), canRegenerate: canRegenerate,
            onCopy: { Clipboard.copy(copyContent(message)) }, onRegenerate: onRegenerate) {
            if message.role == .assistant {
                AssistantMessageView(
                    markdown: ChatContentNormalizer.clean(message.text, references: message.references, internalSegmentIDs: recording.transcript?.segments.map(\.id) ?? []),
                    references: validatedReferences(message.references), onSeek: onSeek)
                SourceReferenceChips(references: SourceReferenceResolver().validate(message.sourceReferences, recording: recording)) { onOpenSource?($0) }
            } else {
                Text(message.text).textSelection(.enabled).font(.callout)
            }
        }
    }

    private func validatedReferences(_ references: [TranscriptReference]) -> [TranscriptReference] {
        guard !references.isEmpty else { return [] }
        return TranscriptReferenceResolver().resolve(
            segmentIDs: references.compactMap { $0.segmentID?.uuidString },
            against: recording.transcript?.segmentSnapshots ?? []
        )
    }

    private func copyContent(_ message: ChatMessage) -> String {
        message.role == .assistant
            ? ChatContentNormalizer.clean(message.text, references: message.references, internalSegmentIDs: recording.transcript?.segments.map(\.id) ?? [])
            : message.text
    }

}

#endif
