import Foundation
import Testing
import Synchronization
@testable import AudioNotes

@MainActor struct OllamaProviderIntegrationTests {
    private func config() -> LocalAIConfiguration {
        let config = LocalAIConfiguration(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        config.localOnly = true
        config.summaryModel = "installed:model"; config.chatModel = "installed:model"
        return config
    }
    @Test func multiSourceSummaryResolvesOnlyAuthoritativeSourceIDs() async throws {
        let recording = try multiSourceFixture()
        let context = SourceSummaryContext(chunks: RecordingContextSnapshot(recording: recording).chunks)
        let chunk = try #require(context.chunks.first { $0.sourceType == .pdf })
        var dto = StructuredSummaryResponse(overview: "The slides discuss kernel modules.", decisions: [.init(text: "Decision", timestampSeconds: 999)])
        dto.referenceChunkIDs = [chunk.id.uuidString, UUID().uuidString]
        let content = String(decoding: try JSONEncoder().encode(dto), as: UTF8.self)
        let fixture = try OllamaRouteFixture(content: content, stream: false)
        defer { fixture.cleanUp() }
        let provider = OllamaLLMProvider(model: "installed:model", configuration: config(), client: OllamaClient(session: fixture.session))
        let result = try await provider.generateSourceSummary(context: context, configuration: .init())
        #expect(result.sourceReferences.map(\.chunkID) == [chunk.id])
        #expect(result.sourceReferences.first?.locator == chunk.locator)
        #expect(result.decisions.first?.timestamp == nil)
        #expect(result.reportedUsage?.outputTokens == 10)
        #expect(result.providerName == "Ollama")
        #expect(fixture.probe.requests.withLock { $0.map { $0.url!.path } } == ["/api/show", "/api/chat"])
    }
    @Test func chatStreamsCleanMarkdownAndValidatesStructuredReferences() async throws {
        let recording = try multiSourceFixture()
        let chunks = RecordingContextSnapshot(recording: recording).chunks
        let chunk = try #require(chunks.first { $0.sourceType == .pdf })
        let response = StructuredChatResponse(answer: "## Answer\n\nThe slide describes a module.", referenceSegmentIDs: [chunk.id.uuidString, UUID().uuidString])
        let fixture = try OllamaRouteFixture(content: String(decoding: JSONEncoder().encode(response), as: UTF8.self), stream: true)
        defer { fixture.cleanUp() }
        var context = ChatContext(recordingTitle: recording.title, transcript: Transcript())
        context.sourceChunks = chunks
        let provider = OllamaLLMProvider(model: "installed:model", configuration: config(), client: OllamaClient(session: fixture.session))
        let stream = try await provider.streamChat(messages: [.init(role: .user, content: "What does the slide describe?")], context: context)
        var text = ""
        var final: LLMChatResponse?
        for try await event in stream {
            if case .textDelta(let delta) = event { text += delta }
            if case .completed(let result) = event { final = result }
        }
        #expect(text == response.answer)
        #expect(final?.content == response.answer)
        #expect(final?.sourceReferences.map(\.chunkID) == [chunk.id])
        #expect(final?.usage?.totalTokens == 30)
        #expect(final?.references.isEmpty == true)
        #expect(!text.contains(chunk.id.uuidString))
    }
    @Test func hierarchicalLocalSummaryAggregatesSequentialRequestsWithoutAPICharges() async throws {
        let recording = try multiSourceFixture()
        for segment in recording.transcript?.segments ?? [] { segment.text = String(repeating: segment.text + "\n", count: 80) }
        let context = SourceSummaryContext(chunks: RecordingContextSnapshot(recording: recording).chunks)
        let dto = StructuredSummaryResponse(overview: "Concise section notes.")
        let fixture = try OllamaRouteFixture(content: String(decoding: JSONEncoder().encode(dto), as: UTF8.self), stream: false)
        defer { fixture.cleanUp() }
        let provider = OllamaLLMProvider(model: "installed:model", configuration: config(), client: OllamaClient(session: fixture.session))
        let record = GenerationRecord(recording: recording, feature: .summary, provider: .ollama, model: provider.modelID,
            presetName: "General", outputLength: .detailed, settings: nil, billingKind: .local)
        let tracker = OperationUsageTracker(generation: record)
        let tracked = UsageTrackingLLMProvider(base: provider, tracker: tracker)
        let result = try await HierarchicalSummaryGenerator(singlePassLimitTokens: 2000).generate(context: context,
            configuration: .init(outputLength: .detailed), provider: tracked)
        tracker.finish(status: .succeeded)
        #expect(result.chunkCount > 1)
        #expect(record.requests.count > 1)
        #expect(record.requests.allSatisfy { $0.cost.billingKind == .local && $0.succeeded })
        #expect(record.outputLengthRaw == OutputLength.detailed.rawValue)
        #expect(record.usageCost.displayText == "Local · No API charge")
        let paths = fixture.probe.requests.withLock { $0.map { $0.url!.path } }
        #expect(paths.enumerated().allSatisfy { $0.element == ($0.offset.isMultiple(of: 2) ? "/api/show" : "/api/chat") })
    }

    @Test func malformedStructuredChatFailsInsteadOfSavingCompletedPartialAnswer() async throws {
        let fixture = try OllamaRouteFixture(content: #"{"answer":"Partial""#, stream: true)
        defer { fixture.cleanUp() }
        let provider = OllamaLLMProvider(model: "installed:model", configuration: config(), client: OllamaClient(session: fixture.session))
        let recording = try multiSourceFixture()
        var context = ChatContext(recordingTitle: recording.title, transcript: Transcript())
        context.sourceChunks = RecordingContextSnapshot(recording: recording).chunks
        var completed = false
        do {
            let stream = try await provider.streamChat(messages: [.init(role: .user, content: "Explain")], context: context)
            for try await event in stream { if case .completed = event { completed = true } }
            Issue.record("Malformed structured output should fail")
        } catch { #expect((error as? ProviderUsageError)?.usage?.outputTokens == 10) }
        #expect(!completed)
    }
}

private final class OllamaRouteProtocol: URLProtocol, @unchecked Sendable {
    struct Scenario: Sendable { let chat: Data; let probe: NetworkProbe }
    static let scenarios = Mutex<[String: Scenario]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let key = request.value(forHTTPHeaderField: "X-Ollama-Test"), let scenario = Self.scenarios.withLock({ $0[key] }) else { return }
        scenario.probe.requests.withLock { $0.append(request) }
        let metadata = Data(#"{"model_info":{"general.architecture":"llama","llama.context_length":32768},"capabilities":["completion"]}"#.utf8)
        let data = request.url?.path == "/api/show" ? metadata : scenario.chat
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private struct OllamaRouteFixture {
    let key = UUID().uuidString
    let session: URLSession
    let probe = NetworkProbe()
    init(content: String, stream: Bool) throws {
        var bodies: [[String: Any]] = []
        if stream {
            let midpoint = content.index(content.startIndex, offsetBy: content.count / 2)
            bodies.append(["message": ["content": String(content[..<midpoint])], "done": false])
            bodies.append(["message": ["content": String(content[midpoint...])], "done": true, "prompt_eval_count": 20, "eval_count": 10])
        } else { bodies.append(["message": ["content": content], "done": true, "prompt_eval_count": 20, "eval_count": 10]) }
        let data = try bodies.map { try JSONSerialization.data(withJSONObject: $0) }.reduce(into: Data()) { $0.append($1); if stream { $0.append(10) } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaRouteProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Ollama-Test": key]
        session = URLSession(configuration: configuration)
        OllamaRouteProtocol.scenarios.withLock { $0[key] = .init(chat: data, probe: probe) }
    }
    func cleanUp() { session.invalidateAndCancel(); _ = OllamaRouteProtocol.scenarios.withLock { $0.removeValue(forKey: key) } }
}
