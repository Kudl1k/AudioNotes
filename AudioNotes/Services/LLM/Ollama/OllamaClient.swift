import Foundation

struct OllamaModelDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let size: Int64?
    let vision: Bool
    let contextWindow: Int?
    func capabilities(contextLimit: Int) -> LLMModelCapabilities {
        var result = LLMModelCapabilities(supportsStructuredOutput: true, defaultTemperature: 0.7)
        result.input = LLMInputCapabilities(supportsImageInput: vision,
            supportedImageFormats: vision ? ["image/jpeg", "image/png"] : [],
            maximumImagesPerRequest: vision ? 2 : nil, maximumImageBytes: vision ? 5 * 1024 * 1024 : nil,
            contextWindowTokens: min(max(4096, contextLimit), contextWindow ?? 16_384), approximateTokensPerImage: 2048)
        return result
    }
}

struct OllamaChatEnvelope: Decodable, Sendable {
    struct Message: Decodable, Sendable { let content: String? }
    let message: Message?
    let done: Bool?
    let error: String?
    let prompt_eval_count: Int?
    let eval_count: Int?
    let eval_duration: Int?
    let total_duration: Int?
    var usage: GenerationUsage? {
        guard let input = prompt_eval_count, let output = eval_count, input >= 0, output >= 0, input <= Int.max - output else { return nil }
        return GenerationUsage(inputTokens: input, outputTokens: output, totalTokens: input + output,
            providerSpecificUsage: ["eval_duration_ns": eval_duration, "total_duration_ns": total_duration].compactMapValues { $0 })
    }
}

final class OllamaClient: @unchecked Sendable {
    private let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 300; config.timeoutIntervalForResource = 3600
        self.session = session ?? URLSession(configuration: config)
    }
    private func request(endpoint: OllamaEndpoint, path: String, body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: endpoint.url.appendingPathComponent("api").appendingPathComponent(path))
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
    private func data(_ request: URLRequest, endpoint: OllamaEndpoint) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request, delegate: RefuseRedirects())
            guard let http = response as? HTTPURLResponse else { throw LocalAIError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw Self.serverError(data, status: http.statusCode) }
            return data
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw Self.connectionError(error, endpoint: endpoint)
        }
    }
    func models(endpoint: OllamaEndpoint) async throws -> [OllamaModelDescriptor] {
        struct Tags: Decodable { struct Item: Decodable { let name: String; let size: Int64? }; let models: [Item] }
        let bytes = try await data(request(endpoint: endpoint, path: "tags"), endpoint: endpoint)
        guard let tags = try? JSONDecoder().decode(Tags.self, from: bytes) else { throw LocalAIError.invalidResponse }
        var result: [OllamaModelDescriptor] = []
        for item in tags.models {
            try Task.checkCancellation()
            do { result.append(try await model(endpoint: endpoint, id: item.name, size: item.size)) }
            catch let error as LocalAIError {
                switch error {
                case .cloudModel, .missingModel, .inference, .invalidResponse: continue
                default: throw error
                }
            }
        }
        return result.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
    func model(endpoint: OllamaEndpoint, id: String, size: Int64? = nil) async throws -> OllamaModelDescriptor {
        guard !id.isEmpty else { throw LocalAIError.missingModel("No model selected") }
        let bytes = try await data(request(endpoint: endpoint, path: "show", body: ["model": id]), endpoint: endpoint)
        guard let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw LocalAIError.invalidResponse }
        // A loopback server can proxy a cloud model. Require an actual local model architecture.
        guard json["remote_host"] == nil, json["remote_model"] == nil, !id.hasSuffix(":cloud"),
              let info = json["model_info"] as? [String: Any], info["general.architecture"] is String else { throw LocalAIError.cloudModel }
        let capabilities = json["capabilities"] as? [String] ?? []
        if !capabilities.isEmpty && !capabilities.contains("completion") { throw LocalAIError.inference("Choose an Ollama model that supports chat completion.") }
        let architecture = info["general.architecture"] as? String ?? ""
        let window = (info[architecture + ".context_length"] as? NSNumber)?.intValue
        return .init(id: id, size: size, vision: capabilities.contains("vision"), contextWindow: window.flatMap { $0 > 0 ? $0 : nil })
    }
    func payload(model: String, messages: [LLMChatMessage], images: [LLMImageInput], capabilities: LLMModelCapabilities,
                 settings: LLMGenerationSettings?, schema: [String: Any], stream: Bool) throws -> Data {
        guard images.isEmpty || capabilities.input.supportsImageInput else { throw LocalAIError.inference("The selected model does not support image input. Use OCR text or select a vision model.") }
        let sanitized = settings?.sanitized(for: capabilities)
        let ceiling = min(sanitized?.maxOutputTokens ?? 2048, max(256, capabilities.input.contextWindowTokens / 4))
        var options: [String: Any] = ["num_ctx": capabilities.input.contextWindowTokens, "num_predict": ceiling]
        if let value = sanitized?.temperature { options["temperature"] = value }
        if let value = sanitized?.topP { options["top_p"] = value }
        let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
        var wireMessages: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        if let first = wireMessages.first, first["role"] as? String == "system" {
            wireMessages[0]["content"] = (first["content"] as? String ?? "") + "\nRespond as JSON matching this schema:\n" + schemaText
        }
        if !images.isEmpty, let index = messages.lastIndex(where: { $0.role == .user }) {
            wireMessages[index]["images"] = images.map { $0.data.base64EncodedString() }
            wireMessages[index]["content"] = messages[index].content + "\nImage chunk IDs in order: " + images.map { $0.chunkID.uuidString }.joined(separator: ", ")
        }
        let textTokens = TranscriptTokenEstimator.estimate(wireMessages.compactMap { $0["content"] as? String }.joined(separator: "\n"))
        guard textTokens + ceiling + images.count * 2048 + 512 <= capabilities.input.contextWindowTokens else {
            throw LLMError.contextTooLarge(approximateTokens: textTokens)
        }
        return try JSONSerialization.data(withJSONObject: ["model": model, "messages": wireMessages, "format": schema,
            "stream": stream, "options": options, "keep_alive": 0, "truncate": false, "shift": false])
    }
    func generate(endpoint: OllamaEndpoint, payload: Data) async throws -> OllamaChatEnvelope {
        var request = try request(endpoint: endpoint, path: "chat", body: [:]); request.httpBody = payload
        let bytes = try await data(request, endpoint: endpoint)
        guard let result = try? JSONDecoder().decode(OllamaChatEnvelope.self, from: bytes), result.done == true, result.message?.content != nil else { throw LocalAIError.invalidResponse }
        if let error = result.error { throw Self.serverError(Data(), message: error) }
        return result
    }
    func stream(endpoint: OllamaEndpoint, payload: Data) async throws -> AsyncThrowingStream<OllamaChatEnvelope, Error> {
        var request = try request(endpoint: endpoint, path: "chat", body: [:]); request.httpBody = payload
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request, delegate: RefuseRedirects()) }
        catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
            throw Self.connectionError(error, endpoint: endpoint)
        }
        guard let http = response as? HTTPURLResponse else { throw LocalAIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count >= 65_536 { break } }
            throw Self.serverError(data, status: http.statusCode)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var finished = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.isEmpty { continue }
                        guard let event = try? JSONDecoder().decode(OllamaChatEnvelope.self, from: Data(line.utf8)) else { throw LocalAIError.invalidResponse }
                        if let error = event.error { throw Self.serverError(Data(), message: error) }
                        continuation.yield(event)
                        if event.done == true { finished = true; break }
                    }
                    guard finished else { throw LocalAIError.invalidResponse }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else if let error = error as? URLError {
                        continuation.finish(throwing: Self.connectionError(error, endpoint: endpoint))
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    private static func connectionError(_ error: URLError, endpoint: OllamaEndpoint) -> LocalAIError {
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection: .transportSecurityBlocked
        case .notConnectedToInternet, .networkConnectionLost: .networkUnavailable
        case .cannotFindHost, .dnsLookupFailed: .hostNotFound
        case .timedOut: .connectionTimedOut
        default: .unreachable(local: endpoint.executionLocation == .local)
        }
    }
    static func serverError(_ data: Data, status: Int = 500, message: String? = nil) -> LocalAIError {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let detail = message ?? json?["error"] as? String ?? ""
        let lower = detail.lowercased()
        if status == 404 { return .missingModel("Selected Ollama model") }
        if lower.contains("memory") { return .inference("Ollama ran out of memory. Close other applications or choose a smaller model.") }
        if lower.contains("context") { return .inference("The request exceeded this model's context window. Reduce context or choose another model.") }
        if lower.contains("image") { return .inference("This Ollama model rejected image input. Use OCR text or a vision model.") }
        return .inference("Ollama could not complete the request (server status \(status)). Check the server and selected model.")
    }
}
