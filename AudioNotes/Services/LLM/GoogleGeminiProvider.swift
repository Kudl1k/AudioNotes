import Foundation

/// Gemini Developer API over Google's documented OAuth bearer-token flow.
/// This is billed to the configured Google Cloud project, not to Gemini Advanced.
@MainActor
final class GoogleGeminiProvider: LLMProvider {
    let id: LLMProviderID = .gemini
    let displayName = "Google Gemini API"
    var authenticationMethod: ProviderAuthenticationMethod? { .oauth }
    var modelID: String? { model }
    var supportsSourceSummaries: Bool { true }

    private let model: String
    private let oauth: GoogleGeminiOAuthService
    private let session: URLSession
    private let promptBuilder = SummaryPromptBuilder()
    private let chatBuilder = ChatContextBuilder()

    init(model: String = "gemini-3.8-flash", oauth: GoogleGeminiOAuthService = GoogleGeminiOAuthService(), session: URLSession = .shared) {
        self.model = model
        self.oauth = oauth
        self.session = session
    }

    func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
        let text = try promptBuilder.formatTranscript(transcript)
        let prompt = promptBuilder.buildPrompt(transcriptContext: text, configuration: configuration)
        return try await summary(system: prompt.systemMessage, user: prompt.userMessage, configuration: configuration)
    }

    func generateSourceSummary(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Summary {
        let prompt = try context.prompt(configuration: configuration)
        let summary = try await summary(system: prompt.systemMessage, user: prompt.userMessage, configuration: configuration)
        context.resolve(summary, ids: [])
        return summary
    }

    private func summary(system: String, user: String, configuration: SummaryConfiguration) async throws -> Summary {
        let body: [String: Any] = ["system_instruction": ["parts": [["text": system]]], "contents": [["role": "user", "parts": [["text": user]]]], "generationConfig": ["responseMimeType": "application/json", "responseSchema": OpenAILLMRequestDTO.summarySchema()]]
        let data = try await request(body: body)
        let text = try Self.responseText(data)
        guard let json = text.data(using: .utf8), var dto = try? JSONDecoder().decode(OpenAISummaryResponseDTO.self, from: json) else { throw LLMError.invalidResponse }
        dto.reportedUsage = Self.usage(data)
        let result = dto.makeSummary(preset: configuration.preset, providerName: displayName, modelName: model)
        result.reportedUsage = dto.reportedUsage
        return result
    }

    func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let prompt = try chatBuilder.buildPrompt(context: context, history: messages)
        let contents: [[String: Any]] = prompt.messages.map { ["role": $0.role == .assistant ? "model" : "user", "parts": [["text": $0.content]]] }
        let body: [String: Any] = ["system_instruction": ["parts": [["text": prompt.systemInstructions]]], "contents": contents, "generationConfig": ["responseMimeType": "application/json", "responseSchema": StreamingJSONAnswerParser.chatSchema()]]
        return try await chatStream(body: body, transcript: context.transcript)
    }

    private func chatStream(body: [String: Any], transcript: Transcript) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent")!
        components.queryItems = [.init(name: "alt", value: "sse")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in try await oauth.requestHeaders() { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw http.statusCode == 401 ? LLMError.invalidAuthentication : LLMError.rejected(status: http.statusCode) }
        let selectedModel = model
        return AsyncThrowingStream { continuation in
            Task {
                let parser = StreamingJSONAnswerParser()
                var raw = ""
                var usage: GenerationUsage?
                do {
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        guard let candidates = json["candidates"] as? [[String: Any]], let candidate = candidates.first,
                              let content = candidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else { continue }
                        let chunk = parts.compactMap { $0["text"] as? String }.joined()
                        raw += chunk
                        if let delta = parser.append(chunk: chunk), !delta.isEmpty { continuation.yield(.textDelta(delta)) }
                        usage = Self.usage(data) ?? usage
                    }
                    guard let json = raw.data(using: .utf8), let answer = try? JSONDecoder().decode(StructuredChatResponse.self, from: json) else { throw LLMError.invalidResponse }
                    let references = transcript.segments.compactMap { segment in answer.referenceSegmentIDs.contains(segment.id.uuidString) ? TranscriptReference(segmentID: segment.id, startTime: segment.startTime) : nil }
                    if !references.isEmpty { continuation.yield(.references(references)) }
                    let response = LLMChatResponse(content: answer.answer, references: references, usage: usage, modelID: selectedModel)
                    if let usage { continuation.yield(.usage(usage)) }
                    continuation.yield(.completed(response))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    private func request(body: [String: Any]) async throws -> Data {
        let headers = try await oauth.requestHeaders()
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw http.statusCode == 401 ? LLMError.invalidAuthentication : LLMError.rejected(status: http.statusCode) }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as LLMError { throw error }
        catch { throw LLMError.network(code: (error as? URLError)?.errorCode ?? URLError.unknown.rawValue) }
    }

    private static func responseText(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]], let first = candidates.first,
              let content = first["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first else { throw LLMError.invalidResponse }
        return text
    }

    private static func usage(_ data: Data) -> GenerationUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let usage = root["usageMetadata"] as? [String: Any],
              let input = usage["promptTokenCount"] as? Int, let output = usage["candidatesTokenCount"] as? Int else { return nil }
        return GenerationUsage(inputTokens: input, outputTokens: output)
    }
}
