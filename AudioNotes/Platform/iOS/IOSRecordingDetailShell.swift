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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showTranscriptionSettings = false
    @State private var showMove = false
    @State private var showChatSettings = false
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
    private let projectCitation: ProjectCitation?

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
        chatModel: ChatViewModel? = nil,
        projectCitation: ProjectCitation? = nil
    ) {
        self.recording = recording
        self.projectCitation = projectCitation
        let effectiveServices = services ?? AppServices()
        self.services = effectiveServices
        _transcriptionModel = State(initialValue: transcriptionModel ?? RecordingViewModel(recording: recording, resolver: IOSFeatureProviders.transcription(effectiveServices)))
        _summaryModel = State(initialValue: summaryModel ?? SummaryViewModel(recording: recording, resolver: IOSFeatureProviders.llm(effectiveServices)))
        _chatModel = State(initialValue: chatModel ?? ChatViewModel(recording: recording, resolver: IOSFeatureProviders.llm(effectiveServices)))
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("\(AudioTime.format(recording.duration)) · \(recording.importedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if dynamicTypeSize.isAccessibilitySize {
                Picker("Recording content", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
            } else {
                Picker("Recording content", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("recording.content")
            }

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
        .padding(.top, 4)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if tab != .chat {
                IOSGlassControls {
                    IOSCompactPlaybackBar(model: player)
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section { Text(recording.title) }
                    Button(action: { showsUsage = true }) {
                        Label("Usage & Cost", systemImage: "dollarsign.circle")
                    }
                    if recording.transcript != nil {
                        Button(action: { showRegenerateTranscriptConfirm = true }) {
                            Label("Regenerate Transcript…", systemImage: "arrow.clockwise")
                        }
                    }
                    Button("Transcription Settings", systemImage: "slider.horizontal.3") { showTranscriptionSettings = true }
                    Button("Move to Project…", systemImage: "folder") { showMove = true }
                    if recording.project != nil {
                        Button("Remove from Project", systemImage: "folder.badge.minus") {
                            imports.library.move(recording, to: nil, using: SwiftDataProjectRepository(context: context))
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
                }.accessibilityIdentifier("recording.actions")
            }
        }
        .sheet(isPresented: $showChatSettings) { IOSSettingsView(services: services) }
        .sheet(isPresented: $showMove) { IOSMoveRecordingSheet(recording: recording, library: imports.library) }
        .sheet(isPresented: $showTranscriptionSettings) { IOSTranscriptionSettingsSheet(model: transcriptionModel, services: services) }
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
            if case .audio(_, let start, _) = projectCitation?.reference.locator { player.seek(to: start) }
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--performance-fixtures"), ProcessInfo.processInfo.arguments.contains("--ios-audio-review") else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            if ProcessInfo.processInfo.arguments.contains("--ios-review-configuration") { showTranscriptionSettings = true }
            if ProcessInfo.processInfo.arguments.contains("--ios-review-move") { showMove = true }
            if ProcessInfo.processInfo.arguments.contains("--ios-review-summary") { tab = .summary }
            if ProcessInfo.processInfo.arguments.contains("--ios-review-chat") { tab = .chat }
        }
#endif
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

    // MARK: - Transcript Tab

    @ViewBuilder
    private var transcriptTabContent: some View {
        if transcriptionModel.state.isProcessing {
            ScrollView {
                OperationProgressView(
                    title: transcriptionModel.progressSnapshot.map(activityTitle) ?? "Transcribing audio…",
                    status: transcriptionModel.progressSnapshot.flatMap(partStatus),
                    progress: OperationProgressValue(fraction: transcriptionModel.progressSnapshot?.overallProgress ?? transcriptionModel.progress),
                    startedAt: transcriptionModel.progressSnapshot?.startedAt,
                    estimatedRemaining: transcriptionModel.progressSnapshot?.estimatedRemainingTime,
                    cancel: transcriptionModel.cancelTranscription,
                    canCancel: transcriptionModel.state.canCancel
                )
                .padding(.vertical, 16)
            }
        } else if let transcript = recording.transcript, !transcript.segments.isEmpty {
            TranscriptView(transcript: transcript, revealedSegmentID: citedSegmentID, seek: player.seek)
        } else {
            transcriptionPromptContent
        }
    }

    private var citedSegmentID: UUID? {
        guard let projectCitation, projectCitation.recordingID == recording.id,
              case .audio(let ids, _, _) = projectCitation.reference.locator else { return nil }
        return ids.first
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

    private var transcriptionPromptContent: some View {
        ScrollView {
            IOSCreationPrompt(title: "Create Transcript", symbol: "waveform.badge.magnifyingglass",
                description: "Convert this recording into searchable text with timestamps and speakers.") {
                Button { showTranscriptionSettings = true } label: {
                    VStack(spacing: 4) {
                        Text(transcriptionModel.providerName + (transcriptionModel.selectedModelName.map { " · " + $0 } ?? ""))
                            .foregroundStyle(.primary)
                        Text("Change").foregroundStyle(.tint)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .modifier(IOSControlSurface(cornerRadius: 18))
                .accessibilityIdentifier("transcription.configure")
                Button(transcriptionModel.state == .idle ? "Transcribe" : "Retry Transcription") {
                    transcriptionModel.startTranscription(using: SwiftDataTranscriptRepository(context: context))
                }
                .modifier(IOSPrimaryAction())
                .accessibilityIdentifier(transcriptionModel.state == .idle ? "transcription.start" : "transcription.retry")
                if case .failed(let message) = transcriptionModel.state {
                    InlineErrorLabel(message)
                    OpenSettingsLink { Text("Open Settings") }
                }
                Text(transcriptionModel.transcriptionEstimate.displayText).font(.footnote).foregroundStyle(.secondary)
            }
        }
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
                    IOSGlassControls {
                        IOSCompactPlaybackBar(model: player, identifierPrefix: "chat.playback")
                    }
                    .padding(.bottom, 4)
                }

                chatMessageList

            }
            .safeAreaInset(edge: .bottom, spacing: 8) {
                IOSGlassControls {
                    ChatComposer(
                        text: $chatModel.inputText,
                        focusRequest: $chatFocusRequest,
                        placeholder: "Ask about this recording…",
                        canSend: chatModel.canSend,
                        isGenerating: chatModel.isGenerating,
                        onSend: chatModel.sendMessage,
                        onStop: chatModel.stopGeneration,
                        providerTitle: services.llmConfiguration.chatProvider == .openAI && services.llmConfiguration.chatAuthMethod == .chatGPT ? "ChatGPT" : services.llmConfiguration.chatProvider.title,
                        onSettings: { showChatSettings = true },
                        onClear: { chatModel.confirmingClearChat = true }
                    )
                }
                .padding(.bottom, 6)
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
    var identifierPrefix = "playback"
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isSeeking = false
    @State private var seekTime: TimeInterval = 0

    var body: some View {
        VStack(spacing: 4) {
            if typeSize.isAccessibilitySize {
                HStack { playButton; position; Spacer(); duration }
                timeline
            } else {
                HStack(spacing: 10) { playButton; position; timeline; duration }
            }
            if let error = model.sessionError ?? model.playback.errorMessage { InlineErrorLabel(error) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .modifier(IOSControlSurface())
    }
    private var playButton: some View {
        Button(action: model.togglePlayback) {
            Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain).foregroundStyle(.tint)
        .disabled(!model.playback.isLoaded || model.isActivating)
        .accessibilityLabel(model.playback.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier(identifierPrefix + ".toggle")
    }
    private var position: some View {
        Text(OperationDurationFormatter.string(isSeeking ? seekTime : model.playback.currentTime))
            .font(.subheadline.monospacedDigit()).accessibilityLabel("Playback position")
            .accessibilityValue(OperationDurationFormatter.string(isSeeking ? seekTime : model.playback.currentTime))
    }
    private var duration: some View {
        Text(OperationDurationFormatter.string(model.playback.duration))
            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            .accessibilityLabel("Duration")
            .accessibilityValue(OperationDurationFormatter.string(model.playback.duration))
    }
    private var timeline: some View {
        Slider(value: Binding(get: { isSeeking ? seekTime : model.playback.currentTime }, set: {
            seekTime = $0
            if !isSeeking { model.seek(to: $0) }
        }), in: 0...max(model.playback.duration, 0.01), onEditingChanged: { editing in
            if editing { seekTime = model.playback.currentTime; isSeeking = true }
            else { model.seek(to: seekTime); isSeeking = false }
        })
        .disabled(!model.playback.isLoaded)
        .accessibilityLabel("Seek playback")
        .accessibilityValue("\(OperationDurationFormatter.string(model.playback.currentTime)) of \(OperationDurationFormatter.string(model.playback.duration))")
        .accessibilityIdentifier(identifierPrefix + ".position")
    }
}
#endif
