import Foundation
import SwiftUI
import SwiftData

@MainActor
@Observable
final class ChatViewModel {
    // MARK: - Static Suggestions

    static let suggestedPrompts: [String] = [
        "Summarize key decisions made",
        "What action items were assigned?",
        "What were the main topics discussed?",
        "List all questions raised"
    ]

    // MARK: - State

    private(set) var sourceContextInternalIDs: [UUID] = []
    var selectedSourceIDs: Set<UUID>? = nil
    var allowImageUpload = false
    var usesUnifiedContext: Bool { !recording.sources.isEmpty || selectedSourceIDs != nil }
    var hasReadySources: Bool { RecordingContextAvailability.hasContent(recording) }
    var selectedSourcesAvailable: Bool { RecordingContextAvailability.hasContent(recording, selectedSourceIDs: selectedSourceIDs) }
    var providerDescription: String {
        let provider = resolver.resolveChat()
        return [provider.displayName, provider.modelID, provider.executionLocation.title].compactMap { $0 }.joined(separator: " · ")
    }
    var imageInputDescription: String { resolver.resolveChat().executionLocation == .local ? "Images: relevant visuals stay on this Mac" : "Images: relevant visuals are sent to the selected provider" }
    var supportsImageInput: Bool { resolver.resolveChat().inputCapabilities.supportsImageInput }
    var session: ChatSession?
    var inputText: String = ""
    var scrollState = ChatScrollState()
    var scrollPosition = ScrollPosition(edge: .bottom)
    private(set) var sentQuestionID: UUID?
    private(set) var assistantMessageID = UUID()
    var generationState: ChatGenerationState = .idle
    var isGenerating: Bool { generationState.isGenerating }
    var streamingDraft: String? = nil
    var streamingReferences: [TranscriptReference] = []
    var lastError: String? = nil
    var canRetry: Bool = false
    var confirmingClearChat: Bool = false
    private(set) var operationStartedAt: Date?
    private(set) var presentationPhase = "Preparing recording context…"

    // Accumulate every token, but publish at most once per display interval.
    @ObservationIgnored private var pendingDraft = ""
    @ObservationIgnored private var draftPublishTask: Task<Void, Never>?
    @ObservationIgnored private(set) var streamingSegments: [TranscriptSegmentSnapshot] = []
    @ObservationIgnored private(set) var streamingSegmentIDs: [UUID] = []

    // MARK: - Dependencies

    @ObservationIgnored private var lastGeneration: GenerationRecord?
    let recording: Recording
    private let resolver: any LLMProviderResolving
    private var storage: ChatRepository?
    private var activeTask: Task<Void, Never>?

    // MARK: - Initializer

    init(
        recording: Recording,
        resolver: any LLMProviderResolving
    ) {
        self.recording = recording
        self.resolver = resolver
    }

    // MARK: - Lifecycle

    func attachStorage(_ storage: ChatRepository) {
        self.storage = storage
        loadOrCreateSession()
    }

    func loadOrCreateSession() {
        guard let storage = storage else { return }
        do {
            self.session = try storage.getOrCreateSession(for: recording)
        } catch {
            DebugLogService.shared.error(
                subsystem: "ChatViewModel",
                message: "Failed to load/create chat session: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Send / Stop

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !generationState.isGenerating
        && selectedSourcesAvailable
    }

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGenerating, !text.isEmpty, let session = session, let storage = storage else { return }
        guard selectedSourcesAvailable else { return }
        let transcript = recording.transcript ?? Transcript()

        // Clear input field immediately
        inputText = ""
        lastError = nil
        canRetry = false

        // Create and append user message
        let userMessage = ChatMessage(
            role: .user,
            text: text,
            status: .completed
        )

        do {
            try storage.appendMessage(userMessage, to: session)
        } catch {
            inputText = text
            lastError = "Failed to save message: \(error.localizedDescription)"
            generationState = .failed(error.localizedDescription)
            return
        }

        sentQuestionID = userMessage.id

        // Start generation
        generateAssistantResponse(for: session, transcript: transcript)
    }

    func sendSuggestedPrompt(_ prompt: String) {
        guard !isGenerating else { return }
        inputText = prompt
        sendMessage()
    }

    func retry() {
        retryLastMessage()
    }

    func retryLastMessage() {
        guard !isGenerating, let session = session, selectedSourcesAvailable else { return }
        let transcript = recording.transcript ?? Transcript()
        lastError = nil
        canRetry = false
        generateAssistantResponse(for: session, transcript: transcript, isRetry: true)
    }

    func regenerateLastAssistantResponse() {
        guard let session = session, let storage = storage, selectedSourcesAvailable else { return }
        let transcript = recording.transcript ?? Transcript()
        guard !isGenerating else { return }

        let messages = session.orderedMessages
        if let last = messages.last, last.role == .assistant {
            try? storage.deleteMessage(last)
        }
        lastError = nil
        canRetry = false
        generateAssistantResponse(for: session, transcript: transcript)
    }

    func stopGeneration() {
        guard isGenerating else { return }

        draftPublishTask?.cancel()
        draftPublishTask = nil
        let partial = pendingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !partial.isEmpty, let session = session, let storage = storage {
            let interruptedMsg = ChatMessage(
                id: assistantMessageID,
                role: .assistant,
                text: ChatContentNormalizer.clean(partial, references: streamingReferences, streaming: true, internalSegmentIDs: streamingSegmentIDs + sourceContextInternalIDs),
                status: .interrupted,
                references: TranscriptReferenceResolver().resolve(segmentIDs: streamingReferences.compactMap { $0.segmentID?.uuidString }, against: streamingSegments)
            )
            interruptedMsg.generationID = lastGeneration?.id
            lastGeneration?.chatMessageID = interruptedMsg.id
            try? storage.appendMessage(interruptedMsg, to: session)
        }
        streamingDraft = nil
        streamingReferences = []
        generationState = .cancelled
        activeTask?.cancel()
        activeTask = nil
    }

    func clearChat() {
        guard let session = session, let storage = storage else { return }
        stopGeneration()
        do {
            try storage.clearMessages(in: session)
            lastError = nil
            canRetry = false
            generationState = .idle
            scrollState = .init()
            scrollPosition = ScrollPosition(edge: .bottom)
        } catch {
            lastError = "Failed to clear chat: \(error.localizedDescription)"
        }
    }

    // MARK: - Private Helpers

    private func appendStreamingDelta(_ delta: String) {
        pendingDraft.append(delta)
        if streamingDraft == nil {
            streamingDraft = pendingDraft
        }
        guard draftPublishTask == nil else { return }
        draftPublishTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.streamingDraft = self.pendingDraft
            self.draftPublishTask = nil
        }
    }

    private func generateAssistantResponse(for session: ChatSession, transcript: Transcript, isRetry: Bool = false) {
        guard let storage = storage else { return }

        draftPublishTask?.cancel()
        draftPublishTask = nil
        pendingDraft = ""
        assistantMessageID = UUID()
        presentationPhase = "Preparing recording context…"
        generationState = .preparing
        streamingDraft = nil
        streamingReferences = []
        operationStartedAt = .now

        let provider = resolver.resolveChat()
        let settings = resolver.chatSettings()
        let selectionData = try? JSONEncoder().encode(Array(RecordingContextAvailability.readySourceIDs(recording, selectedSourceIDs: selectedSourceIDs)).sorted { $0.uuidString < $1.uuidString })
        let generation: GenerationRecord
        if isRetry, let previous = lastGeneration, previous.selectedSourceIDsData == selectionData, previous.canRetry(provider: provider.id.rawValue, model: provider.modelID, authentication: provider.authenticationMethod) {
            generation = previous
            generation.attemptCount += 1
            generation.statusRaw = GenerationStatus.inProgress.rawValue
            generation.errorCategory = nil
        } else {
            generation = GenerationRecord(recording: recording, feature: .chat, provider: provider.id,
            model: provider.modelID, presetName: nil, outputLength: settings.outputLength, settings: settings,
            authenticationMethod: provider.authenticationMethod, status: .inProgress, billingKind: provider.billingKind)
        }
        generation.selectedSourceIDsData = selectionData
        generation.executionLocationRaw = provider.executionLocation.rawValue
        lastGeneration = generation
        let tracker = OperationUsageTracker(generation: generation) { try? storage.record(generation) }
        try? storage.record(generation)
        let chatContext = ChatContext(
            recordingTitle: recording.title,
            transcript: transcript,
            summary: recording.summary,
            generationSettings: resolver.chatSettings()
        )
        let transcriptSnapshots = transcript.segmentSnapshots
        streamingSegments = transcriptSnapshots
        streamingSegmentIDs = transcriptSnapshots.map(\.id)

        // Map persistent history to LLM messages
        var history: [LLMChatMessage] = session.orderedMessages.compactMap { msg in
            switch msg.role {
            case .user:
                return LLMChatMessage(role: .user, content: msg.text)
            case .assistant:
                guard !msg.text.isEmpty else { return nil }
                return LLMChatMessage(role: .assistant, content: ChatContentNormalizer.clean(msg.text, references: msg.references))
            case .system:
                return nil
            }
        }

        if usesUnifiedContext || provider.inputCapabilities.contextWindowTokens < 100_000 { history = SourceConversationHistory.messages(session: session, recording: recording, selectedSourceIDs: selectedSourceIDs) }
        let sourceSelection = selectedSourceIDs
        let imagePermission = allowImageUpload
        let unified = usesUnifiedContext || provider.inputCapabilities.contextWindowTokens < 100_000
        generationState = .waitingForFirstToken

        activeTask = Task { [weak self, provider, chatContext, storage, transcriptSnapshots] in
            guard let self = self else { return }
            var requestID: UUID?
            var reportedUsage: GenerationUsage?
            defer {
                // A cancelled older request must not cancel the next request's publisher.
                if !Task.isCancelled {
                    self.draftPublishTask?.cancel()
                    self.draftPublishTask = nil
                }
                if generation.statusRaw == GenerationStatus.inProgress.rawValue {
                    if let requestID { tracker.finishRequest(requestID, usage: reportedUsage, succeeded: false) }
                    tracker.finish(status: Task.isCancelled ? .cancelled : .failed)
                }
                try? storage.record(generation)
            }
            do {
                var effectiveContext = chatContext
                if unified {
                    effectiveContext = try await SourceContextPreparation().prepareChat(recording: self.recording,
                        selectedSourceIDs: sourceSelection, history: history, provider: provider, settings: settings, allowImages: imagePermission)
                } else {
                    let query = TranscriptRetrievalQueryBuilder().build(from: history)
                    let retrieved = await Task.detached(priority: .userInitiated) {
                        TranscriptRetriever().retrieve(query: query, segments: transcriptSnapshots)
                    }.value
                    effectiveContext.retrievedSegments = retrieved.segments
                    effectiveContext.retrievalUsed = retrieved.usedRetrieval
                }
                try Task.checkCancellation()
                self.sourceContextInternalIDs = (effectiveContext.sourceChunks ?? []).flatMap { [$0.id, $0.sourceID] }
                generation.imageInputCount += effectiveContext.images.count
                requestID = tracker.beginRequest()
                self.presentationPhase = "Waiting for AI…"
                let stream = try await provider.streamChat(messages: history, context: effectiveContext)

                for try await event in stream {
                    if case .usage(let usage) = event { reportedUsage = usage; continue }
                    if case .completed(let response) = event { reportedUsage = response.usage ?? reportedUsage }
                    guard !Task.isCancelled else { break }

                    switch event {
                    case .usage(let usage): reportedUsage = usage
                    case .textDelta(let delta):
                        if self.generationState != .streaming {
                            self.generationState = .streaming
                        }
                        self.appendStreamingDelta(delta)
                    case .references(let refs):
                        self.streamingReferences = TranscriptReferenceResolver().resolve(segmentIDs: refs.compactMap { $0.segmentID?.uuidString }, against: transcriptSnapshots)
                    case .completed(let rawResponse):
                        var response = ChatContentNormalizer.validated(rawResponse, against: transcriptSnapshots)
                        if unified {
                            let permitted = Set((effectiveContext.sourceChunks ?? []).map(\.id))
                            response.sourceReferences = SourceReferenceResolver().validate(rawResponse.sourceReferences.filter { permitted.contains($0.chunkID) }, recording: self.recording)
                            response.content = ChatContentNormalizer.clean(rawResponse.content, internalSegmentIDs: (effectiveContext.sourceChunks ?? []).flatMap { [$0.id, $0.sourceID] })
                            response.references = []
                        }
                        let assistantMessage = ChatMessage(
                            id: self.assistantMessageID,
                            role: .assistant,
                            text: response.content,
                            status: .completed,
                            references: response.references
                        )
                        assistantMessage.sourceReferences = response.sourceReferences
                        if let requestID {
                            tracker.finishRequest(requestID, usage: response.usage ?? reportedUsage, model: response.modelID, succeeded: true)
                        }
                        tracker.finish(status: .succeeded)
                        assistantMessage.generationID = generation.id
                        generation.chatMessageID = assistantMessage.id
                        generation.characterCount = response.content.count
                        generation.wordCount = response.content.split(whereSeparator: \.isWhitespace).count
                        try storage.appendMessage(assistantMessage, to: session)
                        self.streamingDraft = nil
                        self.streamingReferences = []
                        self.generationState = .completed
                        self.activeTask = nil
                        return
                    }
                }
                try Task.checkCancellation()
                throw LLMError.invalidResponse // A closed stream without a final response must leave the working state.
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                self.streamingDraft = nil
                self.streamingReferences = []
                self.generationState = .cancelled
                self.activeTask = nil
            } catch {
                if let requestID {
                    if ProviderRequestFailure.isKnownPreflight(error) { tracker.discardUnsentRequest(requestID) }
                    else { tracker.finishRequest(requestID, usage: (error as? ProviderUsageError)?.usage ?? reportedUsage, succeeded: false) }
                }
                guard !Task.isCancelled else { return }
                let message: String
                if let llmError = error as? LLMError {
                    message = llmError.localizedDescription
                } else {
                    message = error.localizedDescription
                }

                DebugLogService.shared.error(
                    subsystem: "ChatViewModel",
                    message: "Chat generation failed: \(message)"
                )

                self.lastError = message
                self.canRetry = true
                self.streamingDraft = nil
                self.streamingReferences = []
                self.generationState = .failed(message)
                self.activeTask = nil
            }
        }
    }
}
