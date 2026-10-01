import Foundation

/// Connects to the OpenAI-compatible API exposed by `llama-server`.
/// Model metadata is intentionally not treated as proof of local execution: only the endpoint host
/// determines Local Only eligibility, and non-loopback servers are classified as remote.
@MainActor final class LlamaCppLLMProvider: LLMProvider {
    let id: LLMProviderID = .llamaCpp
    let displayName = "llama.cpp Server"
    let supportsSourceSummaries = true
    let model: String
    let configuration: LocalAIConfiguration
    private let endpoint: OllamaEndpoint?
    private let session: URLSession
    var modelID: String? { model }
    var executionLocation: ProviderExecutionLocation { endpoint?.executionLocation ?? .remote }
    var billingKind: BillingKind { executionLocation == .local ? .local : .unknown }
    var inputCapabilities: LLMInputCapabilities { LLMModelCapabilities.capabilities(for: model, provider: .llamaCpp).input }

    init(model: String, configuration: LocalAIConfiguration, session: URLSession? = nil) {
        self.model = model
        self.configuration = configuration
        endpoint = try? OllamaEndpoint(configuration.llamaCppAddress)
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil; settings.httpCookieStorage = nil; settings.connectionProxyDictionary = [:]
        settings.timeoutIntervalForRequest = 300; settings.timeoutIntervalForResource = 3600
        self.session = session ?? URLSession(configuration: settings)
    }

    func generateSummary(transcript: Transcript, configuration summaryConfiguration: SummaryConfiguration) async throws -> Summary {
        let builder = SummaryPromptBuilder()
        let text = try builder.formatTranscript(transcript)
        let prompt = builder.buildPrompt(transcriptContext: text, configuration: summaryConfiguration)
        let result = try await complete(messages: [.init(role: .system, content: prompt.systemMessage), .init(role: .user, content: prompt.userMessage)], schema: StructuredResponseSchema.summarySchema(), settings: summaryConfiguration.generationSettings)
        guard let dto = try? JSONDecoder().decode(StructuredSummaryResponse.self, from: Data(result.content.utf8)) else { throw LocalAIError.invalidResponse }
        let summary = dto.makeSummary(preset: summaryConfiguration.preset, providerName: displayName, modelName: model)
        summary.decisions = summary.decisions.map { var item = $0; item.timestamp = nil; return item }
        summary.actionItems = summary.actionItems.map { var item = $0; item.timestamp = nil; return item }
        summary.openQuestions = summary.openQuestions.map { var item = $0; item.timestamp = nil; return item }
        summary.importantQuotes = summary.importantQuotes.map { var item = $0; item.timestamp = nil; return item }
        summary.reportedUsage = result.usage
        return summary
    }

    func generateSourceSummary(context: SourceSummaryContext, configuration summaryConfiguration: SummaryConfiguration) async throws -> Summary {
        let prompt = context.prompt(configuration: summaryConfiguration)
        let result = try await complete(messages: [.init(role: .system, content: prompt.systemMessage), .init(role: .user, content: prompt.userMessage)], schema: StructuredResponseSchema.summarySchema(), settings: summaryConfiguration.generationSettings)
        guard let dto = try? JSONDecoder().decode(StructuredSummaryResponse.self, from: Data(result.content.utf8)) else { throw LocalAIError.invalidResponse }
        let summary = dto.makeSummary(preset: summaryConfiguration.preset, providerName: displayName, modelName: model)
        summary.decisions = summary.decisions.map { var item = $0; item.timestamp = nil; return item }
        summary.actionItems = summary.actionItems.map { var item = $0; item.timestamp = nil; return item }
        summary.openQuestions = summary.openQuestions.map { var item = $0; item.timestamp = nil; return item }
        summary.importantQuotes = summary.importantQuotes.map { var item = $0; item.timestamp = nil; return item }
        summary.reportedUsage = result.usage
        context.resolve(summary, ids: dto.referenceChunkIDs ?? [])
        return summary
    }

    func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let prompt = try ChatContextBuilder().buildPrompt(context: context, history: messages)
        let result = try await complete(messages: [.init(role: .system, content: prompt.systemInstructions)] + prompt.messages, schema: StructuredResponseSchema.chatSchema(), settings: context.generationSettings)
        guard let dto = try? JSONDecoder().decode(StructuredChatResponse.self, from: Data(result.content.utf8)) else { throw LocalAIError.invalidResponse }
        let segments = context.retrievedSegments ?? context.transcript.segmentSnapshots
        let references = TranscriptReferenceResolver().resolve(segmentIDs: dto.referenceSegmentIDs, against: segments)
        let sources = SourceReferenceResolver().resolve(chunkIDs: dto.referenceSegmentIDs, against: context.sourceChunks ?? [])
        let completedModelID = model
        return AsyncThrowingStream { continuation in
            if let usage = result.usage { continuation.yield(.usage(usage)) }
            continuation.yield(.textDelta(dto.answer))
            continuation.yield(.references(references))
            continuation.yield(.completed(.init(content: dto.answer, references: references, usage: result.usage, modelID: completedModelID, sourceReferences: sources)))
            continuation.finish()
        }
    }

    private struct Completion: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message? }
        let choices: [Choice]
        let usage: Usage?
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
    }
    private struct Result { let content: String; let usage: GenerationUsage? }

    private func complete(messages: [LLMChatMessage], schema: [String: Any], settings: LLMGenerationSettings?) async throws -> Result {
        guard let endpoint else { throw LocalAIError.invalidEndpoint }
        try configuration.policy.validate(endpoint.executionLocation)
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalAIError.missingModel("No llama.cpp model selected") }
        let url = endpoint.url.appendingPathComponent("v1").appendingPathComponent("chat").appendingPathComponent("completions")
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }, "stream": false,
            "response_format": ["type": "json_schema", "json_schema": ["name": "response", "schema": schema]], "temperature": settings?.temperature ?? 0.7,
            "max_tokens": settings?.maxOutputTokens ?? 2048]
        if let topP = settings?.topP { body["top_p"] = topP }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request, delegate: LlamaCppNoRedirect())
            try Task.checkCancellation()
            try configuration.policy.validate(endpoint.executionLocation)
            guard let http = response as? HTTPURLResponse else { throw LocalAIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw LocalAIError.inference("llama.cpp server returned HTTP \(http.statusCode). Check that llama-server is running and the model is loaded.") }
            guard let completion = try? JSONDecoder().decode(Completion.self, from: data), let content = completion.choices.first?.message?.content else { throw LocalAIError.invalidResponse }
            let usage: GenerationUsage? = if let input = completion.usage?.prompt_tokens, let output = completion.usage?.completion_tokens, input >= 0, output >= 0 { GenerationUsage(inputTokens: input, outputTokens: output, totalTokens: input + output) } else { nil }
            return Result(content: content, usage: usage)
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw LocalAIError.unreachable(local: endpoint.executionLocation == .local)
        }
    }
}

private final class LlamaCppNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
