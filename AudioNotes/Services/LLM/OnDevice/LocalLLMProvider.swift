import Foundation

enum LocalLLMResponseKind: Sendable { case summary, chat }
enum LocalLLMEvent: Sendable { case answerSnapshot(String), completedJSON(String) }
struct LocalLLMRequest: Sendable {
    let instructions: String
    let data: String
    let kind: LocalLLMResponseKind
    let settings: LLMGenerationSettings
}

/// Runtime boundary accepts only value snapshots; tests never need Apple's model or network.
protocol LocalLLMRunning: Sendable {
    func cancelAndUnload() async
    func stream(_ request: LocalLLMRequest) async throws -> AsyncThrowingStream<LocalLLMEvent, Error>
}

extension LocalLLMRunning { func cancelAndUnload() async {} }

@MainActor final class LocalLLMProvider: LLMProvider {
    nonisolated static let modelIdentifier = "apple-system-language-model"
    nonisolated static let modelTitle = "Apple On-device Model"
    let id: LLMProviderID = .onDevice
    let displayName = "On Device"
    var modelID: String? { selectedModel }
    var modelDisplayName: String? { selectedModel == Self.modelIdentifier ? Self.modelTitle : selectedModel }
    private let selectedModel: String
    var executionLocation: ProviderExecutionLocation { .local }
    var billingKind: BillingKind { .local }
    var supportsSourceSummaries: Bool { true }
    var inputCapabilities: LLMInputCapabilities { .init(contextWindowTokens: 4096) }
    private let runtime: any LocalLLMRunning
    private let coordinator: LocalInferenceCoordinator
    init(runtime: any LocalLLMRunning = SystemLocalLLMRuntime(), coordinator: LocalInferenceCoordinator? = nil, selectedModel: String? = nil) {
        self.runtime = runtime; self.coordinator = coordinator ?? LocalInferenceCoordinator(); self.selectedModel = selectedModel ?? Self.modelIdentifier
    }

    func prepareForGeneration() async throws {
        try Task.checkCancellation()
        guard selectedModel == Self.modelIdentifier else { throw LocalAIError.missingModel(selectedModel) }
    }
    /// Reserve output and structured-schema overhead before entering the native runtime.
    static func request(instructions: String, messages: [LLMChatMessage], kind: LocalLLMResponseKind,
                        settings: LLMGenerationSettings) throws -> LocalLLMRequest {
        struct Message: Encodable { let role: String; let content: String }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = String(decoding: try encoder.encode(messages.map { Message(role: $0.role.rawValue, content: $0.content) }), as: UTF8.self)
        let sanitized = settings.sanitized(for: .capabilities(for: modelIdentifier, provider: .onDevice))
        var bounded = sanitized
        bounded.maxOutputTokens = sanitized.maxOutputTokens ?? 1024
        let count = TranscriptTokenEstimator.estimate(instructions + data) + bounded.maxOutputTokens! + 512
        guard count <= 4096 else { throw LLMError.contextTooLarge(approximateTokens: count) }
        return .init(instructions: instructions, data: data, kind: kind, settings: bounded)
    }

    func summaryRequestFits(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Bool {
        let prompt = try context.prompt(configuration: configuration)
        do {
            _ = try Self.request(instructions: prompt.systemMessage, messages: [.init(role: .user, content: prompt.userMessage)],
                kind: .summary, settings: configuration.generationSettings ?? .init())
            return true
        } catch LLMError.contextTooLarge { return false }
    }
    func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
        let builder = SummaryPromptBuilder()
        let prompt = builder.buildPrompt(transcriptContext: try builder.formatTranscript(transcript), configuration: configuration)
        return try await summary(prompt, configuration: configuration).summary
    }
    func generateSourceSummary(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Summary {
        let result = try await summary(context.prompt(configuration: configuration), configuration: configuration)
        context.resolve(result.summary, ids: result.ids)
        return result.summary
    }
    private func summary(_ prompt: SummaryPrompt, configuration: SummaryConfiguration) async throws -> (summary: Summary, ids: [String]) {
        guard prompt.images.isEmpty else { throw LLMError.providerUnavailable("On-device image generation") }
        try await prepareForGeneration()
        let request = try Self.request(instructions: prompt.systemMessage,
            messages: [.init(role: .user, content: prompt.userMessage)], kind: .summary, settings: configuration.generationSettings ?? .init())
        try await coordinator.acquire()
        do {
            let events = try await runtime.stream(request)
            var json: String?
            for try await event in events {
                try Task.checkCancellation()
                if case .completedJSON(let value) = event { json = value }
            }
            guard let json else { throw LLMError.invalidResponse }
            let dto = try JSONDecoder().decode(StructuredSummaryResponse.self, from: Data(json.utf8))
            let summary = dto.makeSummary(preset: configuration.preset, providerName: displayName, modelName: Self.modelTitle)
            // Only authoritative source IDs can authorize navigation.
            summary.decisions = summary.decisions.map { var item = $0; item.timestamp = nil; return item }
            summary.actionItems = summary.actionItems.map { var item = $0; item.timestamp = nil; return item }
            summary.openQuestions = summary.openQuestions.map { var item = $0; item.timestamp = nil; return item }
            summary.importantQuotes = summary.importantQuotes.map { var item = $0; item.timestamp = nil; return item }
            await runtime.cancelAndUnload()
            await coordinator.release()
            return (summary, dto.referenceChunkIDs ?? [])
        } catch {
            await runtime.cancelAndUnload()
            await coordinator.release()
            if Task.isCancelled { throw CancellationError() }
            throw Self.presentable(error)
        }
    }
    func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let prompt = try ChatContextBuilder().buildPrompt(context: context, history: messages)
        guard prompt.images.isEmpty else { throw LLMError.providerUnavailable("On-device image input") }
        try await prepareForGeneration()
        let request = try Self.request(instructions: prompt.systemInstructions, messages: prompt.messages,
            kind: .chat, settings: context.generationSettings ?? .init())
        let segments = context.retrievedSegments ?? context.transcript.segmentSnapshots
        let chunks = context.sourceChunks ?? []
        try await coordinator.acquire()
        let stream: AsyncThrowingStream<LocalLLMEvent, Error>
        do { stream = try await runtime.stream(request) }
        catch { await runtime.cancelAndUnload(); await coordinator.release(); throw Self.presentable(error) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var displayed = ""
                    var finalJSON: String?
                    for try await event in stream {
                        try Task.checkCancellation()
                        switch event {
                        case .answerSnapshot(let answer):
                            guard answer.hasPrefix(displayed) else { throw LLMError.invalidResponse }
                            let delta = String(answer.dropFirst(displayed.count))
                            if !delta.isEmpty { continuation.yield(.textDelta(delta)); displayed = answer }
                        case .completedJSON(let json): finalJSON = json
                        }
                    }
                    guard let finalJSON else { throw LLMError.invalidResponse }
                    let dto = try JSONDecoder().decode(StructuredChatResponse.self, from: Data(finalJSON.utf8))
                    guard dto.answer.hasPrefix(displayed) else { throw LLMError.invalidResponse }
                    if dto.answer.count > displayed.count { continuation.yield(.textDelta(String(dto.answer.dropFirst(displayed.count)))) }
                    let references = TranscriptReferenceResolver().resolve(segmentIDs: dto.referenceSegmentIDs, against: segments)
                    let sources = SourceReferenceResolver().resolve(chunkIDs: dto.referenceSegmentIDs, against: chunks)
                    continuation.yield(.references(references))
                    continuation.yield(.completed(.init(content: dto.answer, references: references, modelID: Self.modelIdentifier, sourceReferences: sources)))
                    await self.runtime.cancelAndUnload()
                    await self.coordinator.release()
                    continuation.finish()
                } catch {
                    await self.runtime.cancelAndUnload()
                    await self.coordinator.release()
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : Self.presentable(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    private static func presentable(_ error: Error) -> Error {
        if error is CancellationError || error is LLMError || error is LocalAIError { return error }
        return LocalAIError.inference("On-device processing failed. Retry or explicitly choose another provider.")
    }
}
