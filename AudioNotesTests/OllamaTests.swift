import Foundation
import Testing
@testable import AudioNotes

@MainActor struct OllamaTests {
    private let endpoint = try! OllamaEndpoint("http://localhost:11434")
    private func fixture(_ text: String, status: Int = 200, error: URLError.Code? = nil, suspend: Bool = false) -> OpenAINetworkFixture {
        OpenAINetworkFixture(status: status, data: Data(text.utf8), error: error, suspend: suspend)
    }
    @Test func discoveryUsesTagsAndShowWithoutAuthentication() async throws {
        let mock = fixture(#"{"models":[{"name":"user-model:7b","size":100}],"model_info":{"general.architecture":"llama","llama.context_length":32768},"capabilities":["completion","vision"]}"#)
        defer { mock.cleanUp() }
        let discovered = try await OllamaClient(session: mock.session).models(endpoint: endpoint)
        #expect(discovered.map(\.id) == ["user-model:7b"])
        #expect(discovered.first?.vision == true)
        #expect(discovered.first?.contextWindow == 32768)
        let requests = mock.probe.requests.withLock { $0 }
        #expect(requests.map { $0.url!.path } == ["/api/tags", "/api/show"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }
    @Test func loopbackCloudProxyIsRejectedBeforeContent() async throws {
        let mock = fixture(#"{"remote_host":"https://ollama.com","remote_model":"cloud-model","model_info":{"general.architecture":"llama"}}"#)
        defer { mock.cleanUp() }
        await #expect(throws: LocalAIError.cloudModel) { try await OllamaClient(session: mock.session).model(endpoint: endpoint, id: "opaque-alias") }
        #expect(mock.probe.requests.withLock { $0.count } == 1)
    }
    @Test func unknownModelMetadataFailsClosed() async throws {
        let mock = fixture(#"{"capabilities":["completion"]}"#)
        defer { mock.cleanUp() }
        await #expect(throws: LocalAIError.cloudModel) { try await OllamaClient(session: mock.session).model(endpoint: endpoint, id: "unknown") }
    }
    @Test func conservativeCapabilitiesAndVisionGate() throws {
        let client = OllamaClient()
        let text = OllamaModelDescriptor(id: "custom", size: nil, vision: false, contextWindow: nil).capabilities(contextLimit: 128000)
        #expect(text.input.contextWindowTokens == 16384)
        #expect(!text.input.supportsImageInput)
        let image = LLMImageInput(sourceID: UUID(), chunkID: UUID(), data: Data([1,2]), mimeType: "image/jpeg")
        #expect(throws: LocalAIError.self) {
            try client.payload(model: "custom", messages: [.init(role: .user, content: "Image")], images: [image], capabilities: text, settings: nil, schema: StructuredResponseSchema.chatSchema(), stream: false)
        }
        let vision = OllamaModelDescriptor(id: "visual", size: nil, vision: true, contextWindow: 8192).capabilities(contextLimit: 16384)
        #expect(vision.input.contextWindowTokens == 8192)
        let payload = try client.payload(model: "visual", messages: [.init(role: .system, content: "Grounded"), .init(role: .user, content: "Image")], images: [image], capabilities: vision, settings: .init(maxOutputTokens: 9000, temperature: 0.2, topP: 0.5), schema: StructuredResponseSchema.chatSchema(), stream: true)
        let json = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.last?["images"] as? [String] == [image.data.base64EncodedString()])
        let options = try #require(json["options"] as? [String: Any])
        #expect(options["num_ctx"] as? Int == 8192)
        #expect(options["num_predict"] as? Int == 2048)
        #expect(options["temperature"] as? Double == 0.2)
        #expect(options["top_p"] as? Double == 0.5)
        #expect(json["keep_alive"] as? Int == 0)
    }
    @Test func fullPromptBudgetBlocksOversizedTextBeforeRequest() throws {
        let client = OllamaClient()
        let capabilities = OllamaModelDescriptor(id: "small", size: nil, vision: false, contextWindow: 4096).capabilities(contextLimit: 4096)
        #expect(throws: LLMError.self) {
            try client.payload(model: "small", messages: [.init(role: .system, content: String(repeating: "Transcript ", count: 5000))], images: [], capabilities: capabilities, settings: nil, schema: StructuredResponseSchema.chatSchema(), stream: true)
        }
    }
    @Test func usageComesOnlyFromFinalReportedCounts() throws {
        let event = try JSONDecoder().decode(OllamaChatEnvelope.self, from: Data(#"{"message":{"content":"Hello"},"done":true,"prompt_eval_count":10,"eval_count":20,"eval_duration":1000000000}"#.utf8))
        #expect(event.usage?.inputTokens == 10)
        #expect(event.usage?.totalTokens == 30)
        #expect(event.usage?.providerSpecificUsage?["eval_duration_ns"] == 1_000_000_000)
        #expect(try JSONDecoder().decode(OllamaChatEnvelope.self, from: Data(#"{"done":true}"#.utf8)).usage == nil)
    }
    @Test func summaryHTTPAndInvalidResponse() async throws {
        let mock = fixture(#"{"message":{"content":"{\"overview\":\"Local summary\"}"},"done":true,"prompt_eval_count":5,"eval_count":8}"#)
        defer { mock.cleanUp() }
        let response = try await OllamaClient(session: mock.session).generate(endpoint: endpoint, payload: Data("{}".utf8))
        #expect(response.message?.content?.contains("Local summary") == true)
        #expect(response.usage?.outputTokens == 8)
        let invalid = fixture("not-json"); defer { invalid.cleanUp() }
        await #expect(throws: LocalAIError.invalidResponse) { try await OllamaClient(session: invalid.session).generate(endpoint: endpoint, payload: Data("{}".utf8)) }
    }
    @Test func streamNDJSONAndTerminalUsage() async throws {
        let mock = fixture("{\"message\":{\"content\":\"First\"},\"done\":false}\n{\"message\":{\"content\":\" second\"},\"done\":true,\"prompt_eval_count\":3,\"eval_count\":4}\n")
        defer { mock.cleanUp() }
        let stream = try await OllamaClient(session: mock.session).stream(endpoint: endpoint, payload: Data("{}".utf8))
        var events: [OllamaChatEnvelope] = []
        for try await event in stream { events.append(event) }
        #expect(events.compactMap { $0.message?.content }.joined() == "First second")
        #expect(events.last?.usage?.totalTokens == 7)
    }
    @Test func malformedTruncatedAndMidstreamErrorsDoNotComplete() async throws {
        for (body, expected) in [
            ("bad-json\n", LocalAIError.invalidResponse),
            ("{\"message\":{\"content\":\"unfinished\"},\"done\":false}\n", .invalidResponse),
            ("{\"error\":\"out of memory\"}\n", .inference("Ollama ran out of memory. Close other applications or choose a smaller model."))] {
            let mock = fixture(body); defer { mock.cleanUp() }
            await #expect(throws: expected) {
                let stream = try await OllamaClient(session: mock.session).stream(endpoint: endpoint, payload: Data("{}".utf8))
                for try await _ in stream {}
            }
        }
    }
    @Test func missingModelAndServerErrors() async throws {
        let mock = fixture(#"{"error":"model not found"}"#, status: 404); defer { mock.cleanUp() }
        await #expect(throws: LocalAIError.missingModel("Selected Ollama model")) { try await OllamaClient(session: mock.session).model(endpoint: endpoint, id: "missing") }
        #expect(OllamaClient.serverError(Data(), message: "context length exceeded") == .inference("The request exceeded this model's context window. Reduce context or choose another model."))
        #expect(OllamaClient.serverError(Data(), message: "image not supported") == .inference("This Ollama model rejected image input. Use OCR text or a vision model."))
    }
    @Test func unavailableServerProducesRemediationWithoutFallback() async throws {
        let mock = fixture("", error: .cannotConnectToHost); defer { mock.cleanUp() }
        await #expect(throws: LocalAIError.unreachable(local: true)) { try await OllamaClient(session: mock.session).models(endpoint: endpoint) }
        #expect(mock.probe.requests.withLock { $0.allSatisfy { $0.url?.host() == "localhost" } })
    }
    @Test func cancellationStopsNetworkRequest() async throws {
        let mock = fixture("", suspend: true); defer { mock.cleanUp() }
        let task = Task { try await OllamaClient(session: mock.session).models(endpoint: endpoint) }
        for await _ in mock.probe.started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(mock.probe.requests.withLock { $0.count } == 1)
    }
    @Test func connectionFailuresHaveSpecificRemediationForDiscoveryAndStreaming() async throws {
        let remote = try OllamaEndpoint("http://mac.lab:11434")
        for (code, expected) in [
            (URLError.Code.appTransportSecurityRequiresSecureConnection, LocalAIError.transportSecurityBlocked),
            (.notConnectedToInternet, .networkUnavailable),
            (.networkConnectionLost, .networkUnavailable),
            (.cannotFindHost, .hostNotFound),
            (.dnsLookupFailed, .hostNotFound),
            (.timedOut, .connectionTimedOut),
            (.cannotConnectToHost, .unreachable(local: false))
        ] {
            let mock = fixture("", error: code); defer { mock.cleanUp() }
            let client = OllamaClient(session: mock.session)
            await #expect(throws: expected) { try await client.models(endpoint: remote) }
            await #expect(throws: expected) { try await client.stream(endpoint: remote, payload: Data("{}".utf8)) }
        }
    }
}
