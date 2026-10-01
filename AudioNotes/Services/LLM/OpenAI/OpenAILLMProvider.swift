import Foundation

@MainActor
final class OpenAILLMProvider: LLMProvider {
    var supportsSourceSummaries: Bool { true }
    let id: LLMProviderID = .openAI
    var displayName: String { "OpenAI" }
    var authenticationMethod: ProviderAuthenticationMethod? { .apiKey }

    var modelID: String? { defaultModel }
    private let defaultModel: String
    private let credentials: any CredentialStoring
    private let client: OpenAILLMClient
    private let promptBuilder: SummaryPromptBuilder
    private let chatContextBuilder: ChatContextBuilder

    init(
        defaultModel: String = OpenAILLMModel.gpt4oMini.rawValue,
        credentials: any CredentialStoring,
        client: OpenAILLMClient = OpenAILLMClient(),
        promptBuilder: SummaryPromptBuilder = SummaryPromptBuilder(),
        chatContextBuilder: ChatContextBuilder = ChatContextBuilder()
    ) {
        self.defaultModel = defaultModel
        self.credentials = credentials
        self.client = client
        self.promptBuilder = promptBuilder
        self.chatContextBuilder = chatContextBuilder
    }

    func generateSummary(
        transcript: Transcript,
        configuration: SummaryConfiguration
    ) async throws -> Summary {
        try Task.checkCancellation()

        let key: String?
        do {
            key = try await credentials.apiKey(for: .openAI)
        } catch {
            throw LLMError.missingAPIKey
        }

        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.missingAPIKey
        }

        let context = try promptBuilder.formatTranscript(transcript)
        let prompt = promptBuilder.buildPrompt(transcriptContext: context, configuration: configuration)
        let model = configuration.modelName ?? defaultModel

        DebugLogService.shared.info(
            subsystem: "OpenAILLMProvider",
            message: "Generating summary: model=\(model), preset=\(configuration.preset.rawValue)"
        )

        let dto = try await client.generateSummary(
            prompt: prompt,
            model: model,
            apiKey: key,
            settings: configuration.generationSettings
        )

        let summary = dto.makeSummary(
            preset: configuration.preset,
            providerName: displayName,
            modelName: model
        )
        summary.reportedUsage = dto.reportedUsage
        return summary
    }

    func generateSourceSummary(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Summary {
        try Task.checkCancellation()
        guard let key = try await credentials.apiKey(for: .openAI), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.missingAPIKey }
        let model = configuration.modelName ?? defaultModel
        let dto = try await client.generateSummary(prompt: context.prompt(configuration: configuration), model: model, apiKey: key, settings: configuration.generationSettings)
        let summary = dto.makeSummary(preset: configuration.preset, providerName: displayName, modelName: model)
        summary.reportedUsage = dto.reportedUsage
        context.resolve(summary, ids: dto.referenceChunkIDs ?? [])
        return summary
    }

    func streamChat(
        messages: [LLMChatMessage],
        context: ChatContext
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        try Task.checkCancellation()

        let key: String?
        do {
            key = try await credentials.apiKey(for: .openAI)
        } catch {
            throw LLMError.missingAPIKey
        }

        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.missingAPIKey
        }

        let prompt = try chatContextBuilder.buildPrompt(context: context, history: messages)
        let snapshots = context.sourceChunks == nil ? context.transcript.segmentSnapshots : []

        DebugLogService.shared.info(
            subsystem: "OpenAILLMProvider",
            message: "Streaming chat: model=\(defaultModel), messagesCount=\(messages.count)"
        )

        return try await client.streamChat(
            prompt: prompt,
            model: defaultModel,
            apiKey: key,
            segments: snapshots,
            sourceChunks: context.sourceChunks ?? [],
            settings: context.generationSettings
        )
    }
}
