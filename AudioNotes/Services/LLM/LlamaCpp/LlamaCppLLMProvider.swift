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
    private var serverContextTokens: Int?
    var modelID: String? { model }
    var executionLocation: ProviderExecutionLocation { endpoint?.executionLocation ?? .remote }
    var billingKind: BillingKind { executionLocation == .local ? .local : .unknown }
    var inputCapabilities: LLMInputCapabilities { LLMInputCapabilities(contextWindowTokens: serverContextTokens ?? 4096) }

    func prepareForGeneration() async throws {
        struct Properties: Decodable {
            struct Generation: Decodable { let n_ctx: Int }
            let default_generation_settings: Generation
        }
        let data = try await send(path: "props")
        guard let props = try? JSONDecoder().decode(Properties.self, from: data),
              props.default_generation_settings.n_ctx > 0 else {
            throw LocalAIError.inference("llama.cpp did not report a usable context size from /props. Check the server version and selected model.")
        }
        serverContextTokens = props.default_generation_settings.n_ctx
    }

    private func outputCeiling(_ settings: LLMGenerationSettings?) -> Int {
        min(max(1, settings?.maxOutputTokens ?? 2048), max(1, inputCapabilities.contextWindowTokens / 4))
    }

    private func inputTokenCount(messages: [LLMChatMessage]) async throws -> Int {
        struct Template: Decodable { let prompt: String }
        struct Tokens: Decodable { let tokens: [Int] }
        let templateData = try await send(path: "apply-template", body: ["model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }])
        guard let template = try? JSONDecoder().decode(Template.self, from: templateData) else { throw LocalAIError.invalidResponse }
        let tokenData = try await send(path: "tokenize", body: ["model": model, "content": template.prompt,
            "add_special": true, "parse_special": true])
        guard let result = try? JSONDecoder().decode(Tokens.self, from: tokenData) else { throw LocalAIError.invalidResponse }
        return result.tokens.count
    }

    func summaryRequestFits(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Bool {
        if serverContextTokens == nil { try await prepareForGeneration() }
        let prompt = try context.prompt(configuration: configuration)
        let count = try await inputTokenCount(messages: [.init(role: .system, content: prompt.systemMessage), .init(role: .user, content: prompt.userMessage)])
        return count + outputCeiling(configuration.generationSettings) + 256 <= inputCapabilities.contextWindowTokens
    }

    private func send(path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let endpoint else { throw LocalAIError.invalidEndpoint }
        try Task.checkCancellation()
        try configuration.policy.validate(endpoint.executionLocation)
        guard var components = URLComponents(url: endpoint.url.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { throw LocalAIError.invalidEndpoint }
        if body == nil { components.queryItems = [.init(name: "model", value: model)] }
        guard let url = components.url else { throw LocalAIError.invalidEndpoint }
        var request = URLRequest(url: url)
        // HTTP llama-server/router connections can close between consecutive sizing
        // requests. Avoid reusing those connections; HTTPS retains normal pooling.
        if url.scheme == "http" { request.setValue("close", forHTTPHeaderField: "Connection") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // These read-only operations are safe to repeat even though sizing uses POST.
        // Keep inference outside this retry path: a lost response can hide completed work.
        let retryable = ["props", "apply-template", "tokenize"].contains(path)
        var retried = false
        while true {
            try Task.checkCancellation()
            try configuration.policy.validate(endpoint.executionLocation)
            do {
                let (data, response) = try await session.data(for: request, delegate: LlamaCppNoRedirect())
                try Task.checkCancellation()
                try configuration.policy.validate(endpoint.executionLocation)
                guard let http = response as? HTTPURLResponse else { throw LocalAIError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw serverError(status: http.statusCode, data: data) }
                return data
            } catch let error as URLError {
                if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
                if retryable && !retried && error.code == .networkConnectionLost {
                    retried = true
                    continue
                }
                throw LocalServerConnectionError(provider: id, address: endpoint.url.absoluteString, operation: "/" + path, code: error.code)
            }
        }
    }

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
        let prompt = try context.prompt(configuration: summaryConfiguration)
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

    private struct ServerError: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    private func serverError(status: Int, data: Data) -> LocalAIError {
        let prefix = "llama.cpp server returned HTTP \(status)."
        if let response = try? JSONDecoder().decode(ServerError.self, from: data) {
            let message = response.error.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                // Display only the server's bounded diagnostic, never dump/log the response body.
                return .inference(prefix + " " + String(message.prefix(1_000)))
            }
        }
        let guidance: String = switch status {
        case 400: "The server rejected the request. Check its log for the reason, including model, chat-template, schema, and context-window compatibility."
        case 401, 403: "The server requires authorization or denied access."
        case 404: "Check the server address and loaded model name."
        case 503: "The server is unavailable or still loading the model. Try again when it is ready."
        default: "Check the llama-server log for details."
        }
        return .inference(prefix + " " + guidance)
    }

    private func complete(messages: [LLMChatMessage], schema: [String: Any], settings: LLMGenerationSettings?) async throws -> Result {
        guard let endpoint else { throw LocalAIError.invalidEndpoint }
        try configuration.policy.validate(endpoint.executionLocation)
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalAIError.missingModel("No llama.cpp model selected") }
        if serverContextTokens == nil { try await prepareForGeneration() }
        let inputTokens = try await inputTokenCount(messages: messages)
        guard inputTokens + outputCeiling(settings) + 256 <= inputCapabilities.contextWindowTokens else {
            throw LLMError.contextTooLarge(approximateTokens: inputTokens)
        }
        let url = endpoint.url.appendingPathComponent("v1").appendingPathComponent("chat").appendingPathComponent("completions")
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }, "stream": false,
            // llama.cpp's documented envelope retains schema-constrained generation
            // and also works with servers predating the OpenAI json_schema wrapper.
            "response_format": ["type": "json_object", "schema": schema], "temperature": settings?.temperature ?? 0.7,
            "max_tokens": outputCeiling(settings)]
        if let topP = settings?.topP { body["top_p"] = topP }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request, delegate: LlamaCppNoRedirect())
            try Task.checkCancellation()
            try configuration.policy.validate(endpoint.executionLocation)
            guard let http = response as? HTTPURLResponse else { throw LocalAIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw serverError(status: http.statusCode, data: data) }
            guard let completion = try? JSONDecoder().decode(Completion.self, from: data), let content = completion.choices.first?.message?.content else { throw LocalAIError.invalidResponse }
            let usage: GenerationUsage? = if let input = completion.usage?.prompt_tokens, let output = completion.usage?.completion_tokens, input >= 0, output >= 0 { GenerationUsage(inputTokens: input, outputTokens: output, totalTokens: input + output) } else { nil }
            return Result(content: content, usage: usage)
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw LocalServerConnectionError(provider: id, address: endpoint.url.absoluteString, operation: "/v1/chat/completions", code: error.code)
        }
    }
}

private final class LlamaCppNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
