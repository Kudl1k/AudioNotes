#if os(iOS)
import SwiftUI
import SwiftData
import AVFoundation
import QuickLook

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
    @State private var showsSharing = false
    @State private var showsAttachments = false
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
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            if dynamicTypeSize.isAccessibilitySize {
                Picker("Recording content", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
            } else {
                Picker("Recording content", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("recording.content")
            }

            if tab != .transcript || hasTranscriptSegments {
                transcriptionStatus
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
                    Button("Share Recording Copy…", systemImage: "square.and.arrow.up") { showsSharing = true }
                        .disabled(recording.transcript?.segments.isEmpty != false)
                    Button(action: { showsUsage = true }) {
                        Label("Usage & Cost", systemImage: "dollarsign.circle")
                    }
                    if recording.sources.contains(where: { !$0.isPrimaryAudio }) {
                        Button("Attachments", systemImage: "paperclip") { showsAttachments = true }
                    }
                    if recording.transcript != nil {
                        Button(action: { showRegenerateTranscriptConfirm = true }) {
                            Label("Regenerate Transcript…", systemImage: "arrow.clockwise")
                        }
                        .disabled(!transcriptionModel.canRegenerate)
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
        .sheet(isPresented: $showsAttachments) {
            IOSRecordingAttachments(recording: recording, storage: imports.library.projectImports.storage)
        }
        .sheet(isPresented: $showsSharing) {
            RecordingSharingSheet(recording: recording, storage: imports.library.projectImports.storage)
        }
        .sheet(isPresented: $showChatSettings) { IOSSettingsView(services: services, initialSection: .chat) }
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
        if let transcript = recording.transcript, !transcript.segments.isEmpty {
            TranscriptView(transcript: transcript, revealedSegmentID: citedSegmentID, seek: player.seek)
        } else {
            GeometryReader { geometry in
                ScrollView {
                    Group {
                        switch transcriptionModel.state {
                        case .idle, .completed:
                            transcriptionPromptContent
                        case .preparing, .transcribing, .saving, .failed, .cancelled:
                            transcriptionStatus
                        }
                    }
                    .frame(maxWidth: 420)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
        }
    }

    private var hasTranscriptSegments: Bool {
        recording.transcript?.segments.isEmpty == false
    }

    @ViewBuilder
    private var transcriptionStatus: some View {
        switch transcriptionModel.state {
        case .preparing, .transcribing, .saving:
            if tab == .transcript {
                transcriptionProgressPanel
            } else {
                transcriptionStatusLink(transcriptionModel.iosTranscriptionActivityTitle, systemImage: "waveform")
            }
        case .failed(let message):
            if tab == .transcript {
                VStack(spacing: 6) {
                    Text("Transcription failed").font(.callout.weight(.semibold))
                    InlineErrorLabel(message)
                    transcriptionRecoveryAction
                    OpenSettingsLink { Text("Open Settings") }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                transcriptionStatusLink("Transcription failed", systemImage: "exclamationmark.circle")
            }
        case .cancelled:
            if tab == .transcript {
                VStack(spacing: 6) {
                    Label("Transcription cancelled", systemImage: "xmark.circle").font(.callout)
                    transcriptionRecoveryAction
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        case .idle, .completed:
            EmptyView()
        }
    }

    private var transcriptionProgressPanel: some View {
        let snapshot = transcriptionModel.progressSnapshot
        let phase = snapshot?.phase
        let showsAudioProgress = phase == .transcribing || phase == .uploading || phase == .processing
        let fraction = showsAudioProgress ? snapshot?.overallProgress : nil

        return VStack(spacing: 8) {
            if let fraction {
                Text(transcriptionModel.iosTranscriptionActivityTitle).font(.headline)
                ProgressView(value: fraction)
                    .accessibilityLabel(transcriptionModel.iosTranscriptionActivityTitle)
                    .frame(maxWidth: 240)
            } else {
                ProgressView(transcriptionModel.iosTranscriptionActivityTitle)
            }
            if showsAudioProgress, let status = processedAudioStatus(snapshot) {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
            if let snapshot {
                OperationElapsedTimeView(startedAt: snapshot.startedAt,
                                         estimatedRemaining: showsAudioProgress ? snapshot.estimatedRemainingTime : nil)
            }
            if transcriptionModel.state.canCancel {
                Button(role: .cancel, action: transcriptionModel.cancelTranscription) {
                    Text("Cancel")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Cancel transcription")
                .accessibilityIdentifier("progress.cancel")
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityIdentifier("transcription.activity")
    }

    private func transcriptionStatusLink(_ title: String, systemImage: String) -> some View {
        Button {
            tab = .transcript
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .font(.footnote)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityHint("Opens Transcript")
    }

    @ViewBuilder
    private var transcriptionRecoveryAction: some View {
        if transcriptionModel.canTranscribe || transcriptionModel.canRegenerate {
            HStack(spacing: 12) {
                Button("Reset", role: .destructive) {
                    transcriptionModel.resetTranscription()
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("transcription.reset")

                Button(transcriptionModel.hasCheckpoint ? "Resume Transcription" : "Retry Transcription") {
                    transcriptionModel.startTranscription(
                        using: SwiftDataTranscriptRepository(context: context),
                        replacingExisting: recording.transcript != nil
                    )
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("transcription.retry")
            }
        }
    }

    private func processedAudioStatus(_ snapshot: TranscriptionProgressSnapshot?) -> String? {
        guard let snapshot, let processed = snapshot.processedAudioDuration, processed > 0,
              let total = snapshot.totalAudioDuration, total > 0 else { return snapshot?.partDescription }
        return "\(AudioTime.format(processed)) of \(AudioTime.format(total)) audio processed"
    }

    private var citedSegmentID: UUID? {
        guard let projectCitation, projectCitation.recordingID == recording.id,
              case .audio(let ids, _, _) = projectCitation.reference.locator else { return nil }
        return ids.first
    }

    private var transcriptionPromptContent: some View {
        ContentUnavailableView {
            Label("Create Transcript", systemImage: "waveform.badge.magnifyingglass")
        } description: {
            Text("Convert this recording into searchable text.")
        } actions: {
            Button("Transcribe Recording") {
                transcriptionModel.startTranscription(using: SwiftDataTranscriptRepository(context: context))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!transcriptionModel.canTranscribe)
            .accessibilityIdentifier("transcription.start")

            Button {
                showTranscriptionSettings = true
            } label: {
                Label(transcriptionModel.providerName + (transcriptionModel.selectedModelName.map { " · " + $0 } ?? ""),
                      systemImage: "slider.horizontal.3")
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Change transcription settings")
            .accessibilityIdentifier("transcription.configure")
            if (transcriptionModel.selectedProvider ?? services.configuration.selectedProvider) == .localWhisper,
               let descriptor = services.localAISettings.models.first(where: { $0.id == (transcriptionModel.selectedModel ?? services.llmConfiguration.localAI.whisperModel) }) {
                IOSWhisperModelRow(model: descriptor, settings: services.localAISettings).padding(.horizontal)
            }
            Text(transcriptionModel.transcriptionEstimate.displayText).font(.footnote).foregroundStyle(.secondary)
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
private struct IOSRecordingAttachments: View {
    let recording: Recording
    let storage: LibraryStorage
    @Environment(\.dismiss) private var dismiss
    @State private var preview: URL?

    var body: some View {
        NavigationStack {
            List(recording.sources.filter { !$0.isPrimaryAudio }.sorted { $0.displayName < $1.displayName }) { source in
                Button {
                    preview = storage.sourceURL(source)
                } label: {
                    Label(source.displayName, systemImage: source.type.icon)
                }
            }
            .navigationTitle("Attachments")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .quickLookPreview($preview)
        }
    }
}
#endif
