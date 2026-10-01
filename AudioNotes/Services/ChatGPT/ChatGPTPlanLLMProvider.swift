import Foundation

@MainActor
final class ChatGPTPlanLLMProvider: LLMProvider {
    var supportsSourceSummaries: Bool { true }
    let id: LLMProviderID = .openAI
    let displayName: String = "OpenAI (ChatGPT Plan)"
    var authenticationMethod: ProviderAuthenticationMethod? { .chatGPTAccount }

    var modelID: String? { defaultModel }
    private let defaultModel: String
    private let tokenRefresher: any ChatGPTTokenRefreshing
    private let responsesClient: ChatGPTResponsesClient
    private let promptBuilder: SummaryPromptBuilder
    private let chatContextBuilder: ChatContextBuilder

    init(
        defaultModel: String = "gpt-4o",
        tokenRefresher: any ChatGPTTokenRefreshing = ChatGPTTokenRefresher(),
        responsesClient: ChatGPTResponsesClient = ChatGPTResponsesClient(),
        promptBuilder: SummaryPromptBuilder = SummaryPromptBuilder(),
        chatContextBuilder: ChatContextBuilder = ChatContextBuilder()
    ) {
        self.defaultModel = defaultModel
        self.tokenRefresher = tokenRefresher
        self.responsesClient = responsesClient
        self.promptBuilder = promptBuilder
        self.chatContextBuilder = chatContextBuilder
    }

    func generateSummary(
        transcript: Transcript,
        configuration: SummaryConfiguration
    ) async throws -> Summary {
        try Task.checkCancellation()

        let context = try promptBuilder.formatTranscript(transcript)
        let prompt = promptBuilder.buildPrompt(transcriptContext: context, configuration: configuration)
        let model = configuration.modelName ?? defaultModel

        DebugLogService.shared.info(
            subsystem: "ChatGPTPlanLLMProvider",
            message: "Generating summary: model=\(model), preset=\(configuration.preset.rawValue)"
        )

        let token = try await tokenRefresher.validAccessToken()

        try Task.checkCancellation()

        let dto = try await responsesClient.generateStructuredSummary(
            accessToken: token,
            model: model,
            systemPrompt: prompt.systemMessage,
            userPrompt: prompt.userMessage,
            schema: OpenAILLMRequestDTO.summarySchema(),
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
        let prompt = try context.prompt(configuration: configuration)
        let model = configuration.modelName ?? defaultModel
        let token = try await tokenRefresher.validAccessToken()
        let dto = try await responsesClient.generateStructuredSummary(accessToken: token, model: model,
            systemPrompt: prompt.systemMessage, userPrompt: prompt.userMessage, schema: OpenAILLMRequestDTO.summarySchema(),
            settings: configuration.generationSettings, images: prompt.images)
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

        let prompt = try chatContextBuilder.buildPrompt(context: context, history: messages)
        let snapshots = context.sourceChunks == nil ? context.transcript.segmentSnapshots : []

        DebugLogService.shared.info(
            subsystem: "ChatGPTPlanLLMProvider",
            message: "Streaming chat: model=\(defaultModel), messagesCount=\(messages.count)"
        )

        let token = try await tokenRefresher.validAccessToken()

        try Task.checkCancellation()

        return try await responsesClient.streamChat(
            accessToken: token,
            model: defaultModel,
            prompt: prompt,
            segments: snapshots,
            sourceChunks: context.sourceChunks ?? [],
            settings: context.generationSettings
        )
    }
}
