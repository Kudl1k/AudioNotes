import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct SourceMultimodalTests {
    @Test func imageUploadIsOptInSelectedRelevantAndCapabilityBounded() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let recording = try multiSourceFixture()
        let image = try #require(recording.sources.first { $0.type == .image })
        let directory = workspace.storage.sourceDirectory(id: image.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeSourceTestImage(sourceTestImage(text: "diagram"), to: workspace.storage.sourceURL(image), type: "public.png")
        let prep = SourceContextPreparation(storage: workspace.storage)
        let provider = VisionFixtureProvider()
        let question = [LLMChatMessage(role: .user, content: "Explain this diagram")]
        let local = try await prep.prepareChat(recording: recording, selectedSourceIDs: nil, history: question, provider: provider, settings: .init(), allowImages: false)
        #expect(local.images.isEmpty)
        let actual = try await prep.prepareChat(recording: recording, selectedSourceIDs: nil, history: question, provider: provider, settings: .init(), allowImages: true)
        #expect(actual.images.count == 1)
        #expect(actual.images.first?.sourceID == image.id)
        #expect(actual.images.first?.mimeType == "image/jpeg")
        let excluded = try await prep.prepareChat(recording: recording, selectedSourceIDs: [recording.id], history: question, provider: provider, settings: .init(), allowImages: true)
        #expect(excluded.images.isEmpty)
        let irrelevant = try await prep.prepareChat(recording: recording, selectedSourceIDs: nil, history: [.init(role: .user, content: "When is the deadline?")], provider: provider, settings: .init(), allowImages: true)
        #expect(irrelevant.images.isEmpty)
        let textOnly = try await prep.prepareChat(recording: recording, selectedSourceIDs: [image.id], history: question, provider: MockLLMProvider(delayNanoseconds: 0), settings: .init(), allowImages: true)
        #expect(textOnly.images.isEmpty)
        #expect(LLMInputCapabilities.known(model: "o3-mini", provider: .openAI).supportsImageInput == false)
        #expect(LLMInputCapabilities.known(model: "unknown", provider: .openAI).supportsImageInput == false)
    }
    @Test func chatAndSummaryPayloadsIncludeActualImagePartsOnlyForSupportedModels() throws {
        let image = LLMImageInput(sourceID: UUID(), chunkID: UUID(), data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg")
        let messages = [OpenAIChatMessage(role: "system", content: "Grounding rules"), OpenAIChatMessage(role: "user", content: "Explain the diagram")]
        let data = try OpenAILLMRequestDTO.encodeChatPayload(model: "gpt-4o-mini", messages: messages, images: [image])
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadMessages = try #require(json["messages"] as? [[String: Any]])
        #expect(payloadMessages[0]["content"] as? String == "Grounding rules")
        let parts = try #require(payloadMessages[1]["content"] as? [[String: Any]])
        #expect(parts.count == 3)
        #expect(parts.last?["type"] as? String == "image_url")
        #expect((parts.last?["image_url"] as? [String: String])?["url"] == image.dataURL)
        var summary = OpenAILLMRequestDTO(model: "gpt-4o", messages: messages); summary.images = [image]
        #expect(String(decoding: try summary.encodeToData(), as: UTF8.self).contains("image_url"))
        #expect(throws: LLMError.invalidResponse) { try OpenAILLMRequestDTO.encodeChatPayload(model: "o3-mini", messages: messages, images: [image]) }
    }
    @Test func hierarchicalSourceSummaryAggregatesUsageAndPersistsOneVersion() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try multiSourceFixture()
        let source = try #require(recording.sources.first { $0.type == .pdf })
        source.textUnits = try (0..<35).map { try SourceTextUnit(position: $0, text: String(repeating: "kernel lifecycle information ", count: 140), origin: .nativeText, locator: .pdf(pageIndex: $0)) }
        context.insert(recording); try context.save()
        let generation = GenerationRecord(recording: recording, feature: .summary, provider: .openAI, model: "gpt-4o-mini", presetName: "Lecture", outputLength: .detailed, settings: nil, authenticationMethod: .apiKey, status: .inProgress)
        context.insert(generation)
        let tracker = OperationUsageTracker(generation: generation)
        let provider = VisionFixtureProvider()
        let tracked = UsageTrackingLLMProvider(base: provider, tracker: tracker)
        let snapshot = RecordingContextSnapshot(recording: recording)
        let anchor = try #require(snapshot.chunks.first { $0.id == StableSourceID.make("image-\($0.sourceID)") })
        let image = LLMImageInput(sourceID: anchor.sourceID, chunkID: anchor.id, data: Data([1, 2, 3]), mimeType: "image/jpeg")
        let result = try await HierarchicalSummaryGenerator(singlePassLimitTokens: 2500).generate(context: .init(chunks: snapshot.chunks, images: [image]), configuration: .init(outputLength: .detailed), provider: tracked)
        try SwiftDataSummaryRepository(context: context).save(result.summary, for: recording)
        tracker.finish(status: .succeeded); try context.save()
        #expect(provider.calls > 2)
        #expect(provider.imageCalls == 1)
        #expect(provider.imagesHadAuthoritativeAnchors)
        #expect(generation.imageInputCount == 1)
        #expect(generation.requests.count == provider.calls)
        #expect(generation.inputTokens == provider.calls * 100)
        #expect(generation.usageCost.amount != nil)
        #expect(result.summary.outputLength == .detailed)
        #expect(recording.summaryHistory.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<Summary>()) == 1)
        #expect(!result.summary.sourceReferences.isEmpty)
        #expect(SourceReferenceResolver().validate(result.summary.sourceReferences, recording: recording).count == result.summary.sourceReferences.count)
    }
    @Test func imageRegionChipsAndExportLabelsAreGroupedWithoutLosingAuthority() throws {
        let sourceID = UUID()
        let refs = (0..<10).map { index in
            SourceReference(sourceID: sourceID, chunkID: UUID(), sourceName: "Whiteboard", sourceType: .image,
                locator: .image(region: .init(x: 0, y: Double(index) / 10, width: 1, height: 0.1, confidence: 0.9)), excerpt: "Line \(index)")
        }
        let groups = SourceReferencePresentation.groups(refs)
        #expect(groups.count == 1)
        #expect(groups.first?.references.count == 10)
        #expect(groups.first?.label == "Whiteboard · Image")
        let pdf = refs.map { ref in SourceReference(sourceID: sourceID, chunkID: ref.chunkID, sourceName: "Slides", sourceType: .pdf, locator: .pdf(pageIndex: 2), excerpt: ref.excerpt) }
        #expect(SourceReferencePresentation.groups(pdf).count == 1)
        #expect(SourceReferencePresentation.labels(pdf) == ["Slides · p. 3"])
    }
}

@MainActor
private final class VisionFixtureProvider: LLMProvider {
    let id = LLMProviderID.openAI
    let displayName = "Fixture"
    var modelID: String? { "gpt-4o-mini" }
    var authenticationMethod: ProviderAuthenticationMethod? { .apiKey }
    var calls = 0
    var imageCalls = 0
    var imagesHadAuthoritativeAnchors = true
    func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary { throw LLMError.invalidResponse }
    func generateSourceSummary(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Summary {
        calls += 1
        if !context.images.isEmpty { imageCalls += 1 }
        imagesHadAuthoritativeAnchors = imagesHadAuthoritativeAnchors && context.images.allSatisfy { image in context.chunks.contains { $0.id == image.chunkID } }
        let summary = Summary(overview: "Kernel lifecycle.", modelName: "gpt-4o-mini", outputLength: configuration.outputLength)
        summary.reportedUsage = .init(inputTokens: 100, outputTokens: 20, totalTokens: 120)
        context.resolve(summary, ids: context.chunks.prefix(1).map { $0.id.uuidString })
        return summary
    }
    func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> { throw LLMError.invalidResponse }
}

@MainActor
struct SourceProviderTransportTests {
    @Test func responsesTransportSendsImagePartsAndResolvesChunkIDToAuthoritativePage() async throws {
        let recording = try multiSourceFixture()
        let chunks = RecordingContextSnapshot(recording: recording).chunks
        let chunk = try #require(chunks.first { $0.sourceType == .pdf })
        let answer = try JSONEncoder().encode(OpenAIChatResponseDTO(answer: "Slide evidence", referenceSegmentIDs: [chunk.id.uuidString, UUID().uuidString]))
        let delta = try JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": String(decoding: answer, as: UTF8.self)])
        let completed = "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":123,\"output_tokens\":12,\"total_tokens\":135}}}\n\n"
        let fixture = OpenAINetworkFixture(data: Data(("data: " + String(decoding: delta, as: UTF8.self) + "\n\n" + completed).utf8))
        defer { fixture.cleanUp() }
        let image = LLMImageInput(sourceID: UUID(), chunkID: UUID(), data: Data([1, 2, 3]), mimeType: "image/jpeg")
        let prompt = FormattedChatPrompt(systemInstructions: "Grounding", messages: [.init(role: .user, content: "Explain")], images: [image])
        let stream = try await ChatGPTResponsesClient(session: fixture.session).streamChat(accessToken: "test-token", model: "gpt-4o-mini", prompt: prompt, segments: [], sourceChunks: chunks)
        var response: LLMChatResponse?
        for try await event in stream { if case .completed(let completed) = event { response = completed } }
        #expect(response?.sourceReferences.count == 1)
        #expect(response?.sourceReferences.first?.locator == .pdf(pageIndex: 17))
        #expect(response?.usage?.inputTokens == 123)
        let body = try #require(fixture.probe.requestBodies.withLock { $0.first })
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let inputs = try #require(json["input"] as? [[String: Any]])
        let parts = try #require(inputs.first?["content"] as? [[String: Any]])
        #expect(parts.last?["type"] as? String == "input_image")
        #expect(parts.last?["image_url"] as? String == image.dataURL)
        #expect(json["store"] as? Bool == false)
    }
}
