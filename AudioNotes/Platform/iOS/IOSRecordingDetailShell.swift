#if os(iOS)
import SwiftUI
import SwiftData
import AVFoundation

/// Native compact/regular detail; playback observation is confined to its control leaf.
struct IOSRecordingDetailShell: View {
    let recording: Recording
    let services: AppServices
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(IOSAudioImportModel.self) private var imports
    @Environment(\.scenePhase) private var scenePhase

    @State private var player = IOSRecordingPlaybackModel()
    @State private var tab = DetailTab.transcript
    @State private var showDelete = false
    @State private var showRename = false
    @State private var showRegenerateTranscriptConfirm = false
    @State private var showsUsage = false
    @State private var name = ""
    @State private var managementError: String?

    @State private var transcriptionModel: RecordingViewModel
    @State private var summaryModel: SummaryViewModel
    @State private var chatModel: ChatViewModel
    @State private var chatFocusRequest = 0

    private enum DetailTab: String, CaseIterable {
        case transcript = "Transcript"
        case summary = "Summary"
        case chat = "Chat"
    }

    init(
        recording: Recording,
        services: AppServices? = nil,
        transcriptionModel: RecordingViewModel? = nil,
        summaryModel: SummaryViewModel? = nil,
        chatModel: ChatViewModel? = nil
    ) {
        self.recording = recording
        let effectiveServices = services ?? AppServices()
        self.services = effectiveServices
        _transcriptionModel = State(initialValue: transcriptionModel ?? RecordingViewModel(recording: recording, resolver: effectiveServices.transcriptionResolver))
        _summaryModel = State(initialValue: summaryModel ?? SummaryViewModel(recording: recording, resolver: effectiveServices.llmResolver))
        _chatModel = State(initialValue: chatModel ?? ChatViewModel(recording: recording, resolver: effectiveServices.llmResolver))
    }

    var body: some View {
        VStack(spacing: 12) {
            headerMetadataSection

            Picker("Recording content", selection: $tab) {
                ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Group {
                switch tab {
                case .transcript:
                    transcriptTabContent
                case .summary:
                    summaryTabContent
                case .chat:
                    chatTabContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxWidth: 960)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            if tab != .chat {
                IOSPlaybackControls(model: player)
                    .padding()
                    .frame(maxWidth: 800)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { showsUsage = true }) {
                        Label("Usage & Cost", systemImage: "dollarsign.circle")
                    }
                    if recording.transcript != nil {
                        Button(action: { showRegenerateTranscriptConfirm = true }) {
                            Label("Regenerate Transcript…", systemImage: "arrow.clockwise")
                        }
                    }
                    Button("Rename", systemImage: "pencil") {
                        name = recording.title
                        showRename = true
                    }
                    Button("Delete Recording", systemImage: "trash", role: .destructive) {
                        showDelete = true
                    }
                } label: {
                    Label("Recording actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showsUsage) {
            UsageCostView(recordingID: recording.id)
        }
        .alert("Rename Recording", isPresented: $showRename) {
            TextField("Recording name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                imports.library.error = nil
                imports.library.rename(recording, to: name, using: SwiftDataRecordingRepository(context: context))
                managementError = imports.library.error?.message
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete Recording?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete Recording", role: .destructive) {
                player.stop()
                imports.library.error = nil
                let deleted = imports.library.delete(recording, using: SwiftDataRecordingRepository(context: context))
                managementError = imports.library.error?.message
                if deleted { dismiss() }
            }
        } message: {
            Text("This removes the recording, its history, and managed files. The original file is kept.")
        }
        .confirmationDialog("Regenerate Transcript?", isPresented: $showRegenerateTranscriptConfirm, titleVisibility: .visible) {
            Button("Regenerate Transcript", role: .destructive) {
                transcriptionModel.startTranscription(using: SwiftDataTranscriptRepository(context: context), replacingExisting: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current transcript with a newly generated one. Generation history will be recorded.")
        }
        .alert("Recording could not be updated", isPresented: Binding(get: { managementError != nil }, set: { if !$0 { managementError = nil } })) {
            Button("OK") { managementError = nil }
        } message: {
            Text(managementError ?? "")
        }
        .task(id: recording.id) {
            await player.load(url: LibraryStorage().recordingURL(fileName: recording.audioFileName))
        }
        .onDisappear { player.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player.pause() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { player.handleInterruption($0) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { player.handleRouteChange($0) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
            player.stop()
            Task { await player.load(url: LibraryStorage().recordingURL(fileName: recording.audioFileName)) }
        }
    }

    // MARK: - Header

    private var headerMetadataSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(recording.title)
                    .font(.title2.bold())
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)

                ViewThatFits(in: .horizontal) {
                    HStack { metadata }
                    VStack(alignment: .leading) { metadata }
                }

                if let project = recording.project {
                    Label(project.name, systemImage: "folder")
                        .font(.caption)
                        .lineLimit(2)
                }

                Text(recording.originalFileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 120)
    }

    @ViewBuilder private var metadata: some View {
        Label(OperationDurationFormatter.string(recording.duration), systemImage: "clock")
        Text(recording.importedAt.formatted(date: .abbreviated, time: .shortened))
            .foregroundStyle(.secondary)
    }

    // MARK: - Transcript Tab

    @ViewBuilder
    private var transcriptTabContent: some View {
        if transcriptionModel.state.isProcessing {
            VStack(spacing: 20) {
                Spacer()
                OperationProgressView(
                    title: transcriptionModel.progressSnapshot.map(activityTitle) ?? "Transcribing audio…",
                    status: transcriptionModel.progressSnapshot.flatMap(partStatus),
                    progress: OperationProgressValue(fraction: transcriptionModel.progressSnapshot?.overallProgress ?? transcriptionModel.progress),
                    startedAt: transcriptionModel.progressSnapshot?.startedAt,
                    estimatedRemaining: transcriptionModel.progressSnapshot?.estimatedRemainingTime,
                    cancel: transcriptionModel.cancelTranscription,
                    canCancel: transcriptionModel.state.canCancel
                )
                .padding()
                Spacer()
            }
        } else if let transcript = recording.transcript, !transcript.segments.isEmpty {
            TranscriptView(transcript: transcript, seek: player.seek)
        } else {
            transcriptionPromptContent
        }
    }

    private func activityTitle(_ snapshot: TranscriptionProgressSnapshot) -> String {
        switch snapshot.phase {
        case .preparing: "Preparing audio…"
        case .splitting: "Optimizing audio…"
        case .uploading: "Uploading audio…"
        case .processing: "Processing audio…"
        case .transcribing: "Transcribing audio…"
        case .merging: "Combining transcript…"
        case .saving: "Saving transcript…"
        case .completed: "Transcription complete"
        }
    }

    private func partStatus(_ snapshot: TranscriptionProgressSnapshot) -> String? {
        snapshot.partDescription.map { "\($0) · \(snapshot.completedParts) completed" }
    }

    @ViewBuilder
    private var transcriptionPromptContent: some View {
        VStack(spacing: 16) {
            Spacer()
            ContentUnavailableView {
                Label("Transcribe Recording", systemImage: "waveform.badge.magnifyingglass")
            } description: {
                Text("Generate an accurate transcript with timestamps using AI. Recordings over 25MB are automatically split and processed sequentially.")
            } actions: {
                VStack(spacing: 16) {
                    TranscriptionProviderControls(model: transcriptionModel)
                        .frame(maxWidth: 320)

                    Text(transcriptionModel.transcriptionEstimate.displayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if case .failed(let message) = transcriptionModel.state {
                        VStack(spacing: 8) {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)

                            OpenSettingsLink {
                                Text("Open Settings to configure API key…")
                                    .font(.caption)
                            }
                        }
                        .padding(.horizontal)
                    }

                    Button(action: {
                        transcriptionModel.startTranscription(using: SwiftDataTranscriptRepository(context: context))
                    }) {
                        Label(transcriptionModel.state == .idle ? "Transcribe Audio" : "Retry Transcription", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(transcriptionModel.state == .idle ? "transcription.start" : "transcription.retry")
                }
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Summary Tab

    @ViewBuilder
    private var summaryTabContent: some View {
        if recording.transcript == nil && !summaryModel.hasReadySources && recording.summary == nil {
            ContentUnavailableView {
                Label("No Transcript", systemImage: "text.bubble")
            } description: {
                Text("Transcribe this recording first to generate a structured AI summary.")
            } actions: {
                Button("Go to Transcript") {
                    tab = .transcript
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            SummaryView(recording: recording, model: summaryModel, onSeek: player.seek)
        }
    }

    // MARK: - Chat Tab

    @ViewBuilder
    private var chatTabContent: some View {
        if recording.transcript == nil && !chatModel.hasReadySources {
            ContentUnavailableView {
                Label("No Transcript", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Transcribe this recording first to chat with AI about its content.")
            } actions: {
                Button("Go to Transcript") {
                    tab = .transcript
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(spacing: 0) {
                if player.playback.isLoaded {
                    IOSCompactPlaybackBar(model: player)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial)
                }

                chatMessageList

                Divider()

                ChatComposer(
                    text: $chatModel.inputText,
                    focusRequest: $chatFocusRequest,
                    placeholder: "Ask about this recording…",
                    canSend: chatModel.canSend,
                    isGenerating: chatModel.isGenerating,
                    onSend: chatModel.sendMessage,
                    onStop: chatModel.stopGeneration
                )
            }
            .task {
                let storage = SwiftDataChatRepository(context: context)
                chatModel.attachStorage(storage)
            }
            .confirmationDialog(
                "Clear Chat History?",
                isPresented: $chatModel.confirmingClearChat,
                titleVisibility: .visible
            ) {
                Button("Clear Chat", role: .destructive) {
                    chatModel.clearChat()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the conversation history for this recording. Your transcript, summary, and audio file are not affected.")
            }
        }
    }

    private var chatMessageList: some View {
        ChatMessageList(
            scrollState: $chatModel.scrollState,
            scrollPosition: $chatModel.scrollPosition,
            messageCount: chatModel.session?.messages.count ?? 0,
            latestMessageID: chatModel.session?.orderedMessages.last?.id,
            activeResponseID: chatModel.assistantMessageID,
            draft: chatModel.streamingDraft,
            generationState: chatModel.generationState,
            sentQuestionID: chatModel.sentQuestionID
        ) {
            if (chatModel.session?.messages.isEmpty ?? true) && !chatModel.isGenerating {
                chatEmptyStateView
            }

            let messages = chatModel.session?.orderedMessages ?? []
            ForEach(messages) { message in
                ChatMessageBubble(
                    message: message,
                    recording: recording,
                    canRegenerate: message.id == messages.last?.id && !chatModel.isGenerating,
                    onSeek: player.seek,
                    onOpenSource: nil,
                    onRegenerate: chatModel.regenerateLastAssistantResponse
                )
                .id(message.id)
            }

            if chatModel.isGenerating {
                ChatActiveResponse(
                    isStreaming: chatModel.generationState == .streaming,
                    phase: chatModel.presentationPhase,
                    startedAt: chatModel.operationStartedAt
                ) {
                    AssistantMessageView(
                        markdown: ChatContentNormalizer.clean(
                            chatModel.streamingDraft ?? "",
                            references: chatModel.streamingReferences,
                            streaming: true,
                            internalSegmentIDs: chatModel.streamingSegmentIDs + chatModel.sourceContextInternalIDs
                        ),
                        references: validatedChatReferences(chatModel.streamingReferences),
                        onSeek: player.seek
                    )
                }
                .id("active-\(chatModel.assistantMessageID)")
            }

            if let error = chatModel.lastError {
                ChatErrorView(error: error, canRetry: chatModel.canRetry, onRetry: chatModel.retry)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var chatEmptyStateView: some View {
        ChatEmptyState(
            title: "Chat about this recording",
            description: "Ask questions and explore details. Responses include clickable citations to seek the recording."
        ) {
            Text("Suggested questions")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(ChatViewModel.suggestedPrompts, id: \.self) { prompt in
                Button(prompt) {
                    chatModel.sendSuggestedPrompt(prompt)
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .multilineTextAlignment(.leading)
            }
        }
    }

    private func validatedChatReferences(_ references: [TranscriptReference]) -> [TranscriptReference] {
        guard !references.isEmpty else { return [] }
        return TranscriptReferenceResolver().resolve(
            segmentIDs: references.compactMap { $0.segmentID?.uuidString },
            against: chatModel.streamingSegments
        )
    }
}

// MARK: - Playback Controls

private struct IOSCompactPlaybackBar: View {
    let model: IOSRecordingPlaybackModel

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.togglePlayback) {
                Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.callout)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel(model.playback.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("chat.playback.toggle")

            Text(OperationDurationFormatter.string(model.playback.currentTime))
                .font(.caption2.monospacedDigit())

            Slider(value: Binding(
                get: { model.playback.currentTime },
                set: { model.seek(to: $0) }
            ), in: 0...max(model.playback.duration, 0.01))
            .controlSize(.small)
            .accessibilityLabel("Playback position")

            Text(OperationDurationFormatter.string(model.playback.duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct IOSPlaybackControls: View {
    let model: IOSRecordingPlaybackModel
    @State private var scrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { scrubbing ? scrubTime : model.playback.currentTime }, set: {
                scrubTime = $0
                if !scrubbing { model.seek(to: $0) }
            }), in: 0...max(model.playback.duration, 0.01), onEditingChanged: { editing in
                if editing {
                    scrubTime = model.playback.currentTime
                    scrubbing = true
                } else {
                    model.seek(to: scrubTime)
                    scrubbing = false
                }
            })
            .disabled(!model.playback.isLoaded)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(OperationDurationFormatter.string(model.playback.currentTime)) of \(OperationDurationFormatter.string(model.playback.duration))")
            .accessibilityIdentifier("playback.position")

            HStack {
                Text(OperationDurationFormatter.string(scrubbing ? scrubTime : model.playback.currentTime))
                    .monospacedDigit()
                    .accessibilityLabel("Current position")
                    .accessibilityValue(OperationDurationFormatter.string(scrubbing ? scrubTime : model.playback.currentTime))

                Spacer()

                Button(action: model.togglePlayback) {
                    Label(model.playback.isPlaying ? "Pause" : "Play", systemImage: model.playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 80, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.playback.isLoaded || model.isActivating)
                .accessibilityIdentifier("playback.toggle")

                Spacer()

                Text(OperationDurationFormatter.string(model.playback.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Duration")
                    .accessibilityValue(OperationDurationFormatter.string(model.playback.duration))
            }

            if let error = model.sessionError ?? model.playback.errorMessage {
                InlineErrorLabel(error)
            }
        }
        .onChange(of: model.playback.isPlaying) { _, playing in
            if !playing { model.pause() }
        }
    }
}
#endif
