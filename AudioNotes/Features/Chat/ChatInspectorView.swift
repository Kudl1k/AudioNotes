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
    @State private var scrollState = ChatScrollState()
    @FocusState private var isInputFocused: Bool

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
                Label("Chat", systemImage: "bubble.left.and.bubble.right").font(.headline)
                Text(model.providerDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            Spacer()
            Button("Chat usage", systemImage: "dollarsign.circle") { showsUsage = true }
                .labelStyle(.iconOnly).buttonStyle(.plain).help("Chat usage & cost")

            if let session = model.session, !session.messages.isEmpty {
                Button {
                    model.confirmingClearChat = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear chat history").accessibilityLabel("Clear chat history")
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    let hasMessages = !(model.session?.messages.isEmpty ?? true)
                    let isWorking = model.generationState == .preparing || model.generationState == .waitingForFirstToken || model.generationState == .streaming

                    if !hasMessages && !isWorking {
                        emptyStateView
                    } else if model.session != nil {
                        ChatHistoryView(model: model, recording: recording, onSeek: onSeek, onOpenSource: onOpenSource)

                        if model.generationState == .preparing || model.generationState == .waitingForFirstToken {
                            thinkingBubble
                                .id("thinking_state")
                        } else if let draft = model.streamingDraft {
                            streamingBubble(draft)
                                .id("streaming_draft")
                        }

                        if let error = model.lastError {
                            errorBanner(error)
                                .id("chat_error")
                        }
                    }
                    Color.clear.frame(height: 1).id("chat_bottom")
                }
                .padding(14)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height) <= 64
            } action: { _, nearBottom in
                scrollState.positionChanged(nearBottom: nearBottom)
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: scrollState.userScrolling(true)
                case .idle:
                    if scrollState.isUserScrolling { scrollState.userScrolling(false) }
                default: break
                }
            }
            .overlay(alignment: .bottom) {
                if scrollState.hasUnseenContent {
                    Button("Jump to Latest", systemImage: "arrow.down") {
                        scrollState.jumpToLatest()
                        proxy.scrollTo("chat_bottom", anchor: .bottom)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(8)
                    .accessibilityHint("Resume following new answers")
                }
            }
            .onChange(of: model.generationState) { _, state in
                if state.isGenerating && scrollState.contentArrived() {
                    proxy.scrollTo("chat_bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.streamingDraft) { _, _ in
                if scrollState.contentArrived() { proxy.scrollTo("chat_bottom", anchor: .bottom) }
            }
            .onChange(of: model.session?.messages.count) { _, _ in
                if scrollState.contentArrived() { proxy.scrollTo("chat_bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chat about this recording")
                    .font(.subheadline.bold())
                Text("Answers use your selected ready sources with clickable references.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 6)

            Text("Suggested questions")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(ChatViewModel.suggestedPrompts, id: \.self) { prompt in
                    Button {
                        model.sendSuggestedPrompt(prompt)
                    } label: {
                        HStack(alignment: .center, spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                            Text(prompt)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var thinkingBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("AudioNotes")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(model.elapsedSeconds > 0 ? "Thinking… \(model.elapsedSeconds)s" : "Thinking…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func streamingBubble(_ draft: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("AudioNotes")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.mini)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                AssistantMessageView(
                    markdown: ChatContentNormalizer.clean(draft, references: model.streamingReferences, streaming: true, internalSegmentIDs: model.streamingSegmentIDs + model.sourceContextInternalIDs),
                    references: validatedReferences(model.streamingReferences), onSeek: onSeek
                )
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func validatedReferences(_ references: [TranscriptReference]) -> [TranscriptReference] {
        guard !references.isEmpty else { return [] }
        return TranscriptReferenceResolver().resolve(
            segmentIDs: references.compactMap { $0.segmentID?.uuidString },
            against: model.streamingSegments
        )
    }

    private func errorBanner(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if model.canRetry {
                Button("Retry") {
                    model.retry()
                }
                .font(.caption.bold())
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            SettingsLink {
                Label("Choose Chat Provider…", systemImage: "slider.horizontal.3")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var composerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            SourceSelectionView(recording: recording, selectedSourceIDs: $model.selectedSourceIDs,
                allowImageUpload: $model.allowImageUpload, supportsImages: model.supportsImageInput).disabled(model.isGenerating)
            if recording.sources.contains(where: { $0.type == .image && $0.isContextReady }) {
                Text(model.allowImageUpload && model.supportsImageInput ? model.imageInputDescription : "Images: local OCR text only")
                    .font(.caption).foregroundStyle(.secondary)
            }
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this recording…", text: $model.inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .onKeyPress(.return, phases: [.down, .repeat]) { press in
                    if press.modifiers.contains(.shift) {
                        // A vertical TextField ends editing on Return, so insert the line break here.
                        model.inputText.append("\n")
                        return .handled
                    } else if model.canSend {
                        model.sendMessage()
                        return .handled
                    }
                    return .handled
                }

            if model.isGenerating {
                Button {
                    model.stopGeneration()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop generating").accessibilityLabel("Stop generating").keyboardShortcut(.cancelAction)
            } else {
                Button {
                    model.sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .help("Send message (Return)").accessibilityLabel("Send message")
            }
        }
        }
        .padding(12)
    }
}

/// A simple flow layout to display reference chips in rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        // An unspecified or transient nonpositive proposal means the parent has
        // not supplied a useful wrapping width yet. Return the natural size so
        // this layout never feeds a zero/negative width back into SwiftUI.
        guard let proposedWidth = proposal.width, proposedWidth.isFinite, proposedWidth > 0 else {
            let width = sizes.reduce(CGFloat.zero) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * spacing
            return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
        }
        let width = proposedWidth
        var height: CGFloat = 0
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        for size in sizes {
            if x + size.width > width && x > 0 {
                x = 0
                height += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 0, bounds.height >= 0 else { return }
        let wraps = bounds.width > 0
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for (subview, size) in zip(subviews, sizes) {
            if wraps && x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// This subtree observes history and generation state, never the streaming draft.
private struct ChatHistoryView: View {
    let model: ChatViewModel
    let recording: Recording
    var onSeek: ((TimeInterval) -> Void)?
    var onOpenSource: ((SourceReference) -> Void)?

    var body: some View {
        let messages = model.session?.orderedMessages ?? []
        let lastID = messages.last?.id
        ForEach(messages) { message in
            ChatMessageBubble(
                message: message, recording: recording,
                canRegenerate: message.id == lastID && !model.isGenerating,
                onSeek: onSeek, onOpenSource: onOpenSource, onRegenerate: model.regenerateLastAssistantResponse
            )
            .id(message.id)
        }
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
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            HStack(spacing: 6) {
                if message.role == .user {
                    Spacer(minLength: 24)
                    Text("You")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                } else {
                    GenerationDetailsButton(generationID: message.generationID)
                    Text("AudioNotes")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    if message.status == .interrupted {
                        Text("(interrupted)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 24)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if message.role == .assistant {
                    AssistantMessageView(
                        markdown: ChatContentNormalizer.clean(message.text, references: message.references, internalSegmentIDs: recording.transcript?.segments.map(\.id) ?? []),
                        references: validatedReferences(message.references), onSeek: onSeek
                    )
                    SourceReferenceChips(references: SourceReferenceResolver().validate(message.sourceReferences, recording: recording)) { onOpenSource?($0) }
                } else {
                    Text(message.text).textSelection(.enabled).font(.callout)
                }

                if message.role == .assistant {
                    HStack(spacing: 12) {
                        Button {
                            Clipboard.copy(copyContent(message))
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)

                        if canRegenerate {
                            Button {
                                onRegenerate()
                            } label: {
                                Label("Regenerate", systemImage: "arrow.clockwise")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(10)
            .background(
                message.role == .user
                    ? Color.accentColor.opacity(0.15)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contextMenu {
                Button("Copy Message") {
                    Clipboard.copy(copyContent(message))
                }
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
