import Foundation

@MainActor final class OllamaLLMProvider: LLMProvider {
    let id: LLMProviderID = .ollama
    let displayName = "Ollama"
    var supportsSourceSummaries: Bool { true }
    let model: String
    let endpoint: OllamaEndpoint?
    let localConfiguration: LocalAIConfiguration
    let client: OllamaClient
    var modelID: String? { model }
    var executionLocation: ProviderExecutionLocation { endpoint?.executionLocation ?? .remote }
    var billingKind: BillingKind { executionLocation == .local ? .local : .unknown }
    var inputCapabilities: LLMInputCapabilities { localConfiguration.capabilities(model: model).input }
    init(model: String, configuration: LocalAIConfiguration, client: OllamaClient = OllamaClient()) {
        self.model = model; self.localConfiguration = configuration; self.client = client
        endpoint = try? OllamaEndpoint(configuration.ollamaAddress)
    }
    private func verifiedCapabilities() async throws -> (OllamaEndpoint, LLMModelCapabilities) {
        guard let endpoint else { throw LocalAIError.invalidEndpoint }
        try localConfiguration.policy.validate(endpoint.executionLocation)
        let descriptor = try await client.model(endpoint: endpoint, id: model)
        try Task.checkCancellation()
        try localConfiguration.policy.validate(endpoint.executionLocation)
        return (endpoint, descriptor.capabilities(contextLimit: localConfiguration.contextTokens))
    }
    func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
        let builder = SummaryPromptBuilder()
        let text = try builder.formatTranscript(transcript)
        return try await summary(prompt: builder.buildPrompt(transcriptContext: text, configuration: configuration), configuration: configuration)
    }
    func generateSourceSummary(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Summary {
        let result = try await summaryResult(prompt: context.prompt(configuration: configuration), configuration: configuration)
        context.resolve(result.summary, ids: result.ids)
        return result.summary
    }
    private func summary(prompt: SummaryPrompt, configuration: SummaryConfiguration) async throws -> Summary {
        try await summaryResult(prompt: prompt, configuration: configuration).summary
    }
    private func summaryResult(prompt: SummaryPrompt, configuration: SummaryConfiguration) async throws -> (summary: Summary, ids: [String]) {
        let (endpoint, capabilities) = try await verifiedCapabilities()
        let payload = try client.payload(model: model, messages: [.init(role: .system, content: prompt.systemMessage), .init(role: .user, content: prompt.userMessage)],
            images: prompt.images, capabilities: capabilities, settings: configuration.generationSettings, schema: StructuredResponseSchema.summarySchema(), stream: false)
        let response = try await client.generate(endpoint: endpoint, payload: payload)
        guard let content = response.message?.content,
              let dto = try? JSONDecoder().decode(StructuredSummaryResponse.self, from: Data(content.utf8)) else {
            throw ProviderUsageError.preserving(LocalAIError.invalidResponse, usage: response.usage)
        }
        let summary = dto.makeSummary(preset: configuration.preset, providerName: displayName, modelName: model)
        // Local models never authorize clickable times through generated prose or numeric timestamps.
        summary.decisions = summary.decisions.map { var item = $0; item.timestamp = nil; return item }
        summary.actionItems = summary.actionItems.map { var item = $0; item.timestamp = nil; return item }
        summary.openQuestions = summary.openQuestions.map { var item = $0; item.timestamp = nil; return item }
        summary.importantQuotes = summary.importantQuotes.map { var item = $0; item.timestamp = nil; return item }
        summary.reportedUsage = response.usage
        return (summary, dto.referenceChunkIDs ?? [])
    }
    func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let (endpoint, capabilities) = try await verifiedCapabilities()
        let prompt = try ChatContextBuilder().buildPrompt(context: context, history: messages)
        let payload = try client.payload(model: model, messages: [.init(role: .system, content: prompt.systemInstructions)] + prompt.messages,
            images: prompt.images, capabilities: capabilities, settings: context.generationSettings, schema: StructuredResponseSchema.chatSchema(), stream: true)
        let raw = try await client.stream(endpoint: endpoint, payload: payload)
        let segments = context.retrievedSegments ?? context.transcript.segmentSnapshots
        let chunks = context.sourceChunks ?? []
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let parser = StreamingJSONAnswerParser()
                    var usage: GenerationUsage?
                    var structuredText = ""
                    for try await event in raw {
                        try Task.checkCancellation()
                        if let text = event.message?.content {
                            structuredText += text
                            if let delta = parser.append(chunk: text) { continuation.yield(.textDelta(delta)) }
                        }
                        if event.done == true, let reported = event.usage { usage = reported; continuation.yield(.usage(reported)) }
                    }
                    guard let dto = try? JSONDecoder().decode(StructuredChatResponse.self, from: Data(structuredText.utf8)) else {
                        throw ProviderUsageError.preserving(LocalAIError.invalidResponse, usage: usage)
                    }
                    let references = TranscriptReferenceResolver().resolve(segmentIDs: dto.referenceSegmentIDs, against: segments)
                    let sources = SourceReferenceResolver().resolve(chunkIDs: dto.referenceSegmentIDs, against: chunks)
                    continuation.yield(.references(references))
                    continuation.yield(.completed(.init(content: dto.answer, references: references, usage: usage, modelID: self.model, sourceReferences: sources)))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
