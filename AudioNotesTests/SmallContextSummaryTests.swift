import Foundation
import Testing
@testable import AudioNotes

@MainActor
struct SmallContextSummaryTests {
    private final class SmallProvider: LLMProvider {
        let id: LLMProviderID = .llamaCpp
        let displayName = "Small local fixture"
        let executionLocation: ProviderExecutionLocation = .local
        let supportsSourceSummaries = true
        let inputCapabilities = LLMInputCapabilities(contextWindowTokens: 4096)
        var calls: [SourceSummaryContext] = []
        var lengths: [OutputLength] = []
        var prepared = false

        func prepareForGeneration() async throws { prepared = true }
        func summaryRequestFits(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Bool {
            let prompt = try context.prompt(configuration: configuration)
            // Simulate a tokenizer denser than the application's four-byte estimate.
            return (prompt.systemMessage.utf8.count + prompt.userMessage.utf8.count) / 2 + 1024 + 256 <= 4096
        }
        func generateSourceSummary(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Summary {
            #expect(prepared)
            #expect(try await summaryRequestFits(context: context, configuration: configuration))
            calls.append(context)
            lengths.append(configuration.outputLength)
            let summary = Summary(overview: "Section notes", preset: configuration.preset)
            context.resolve(summary, ids: context.chunks.map { $0.id.uuidString })
            return summary
        }
        func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
            Issue.record("Long local summaries must use the bounded source hierarchy")
            throw LLMError.invalidResponse
        }
        func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
            throw LLMError.invalidResponse
        }
    }

    @Test func oversizedChunkIsSplitWithoutLosingTextIDsOrLocations() async throws {
        let original = SourceChunk(id: UUID(), sourceID: UUID(), sourceName: "Czech recording", sourceType: .audio,
            text: String(repeating: "Žluťoučký kůň řeší důležité otázky.\n", count: 2000),
            locator: .audio(segmentIDs: [UUID()], start: 120, end: 480), origin: .transcript)
        let provider = SmallProvider()
        let result = try await HierarchicalSummaryGenerator().generate(context: .init(chunks: [original]),
            configuration: .init(outputLength: .detailed), provider: provider)
        let sourcePasses = provider.calls.filter { $0.intermediateNotes.isEmpty }
        let fragments = sourcePasses.flatMap(\.chunks)
        #expect(result.chunkCount > 1)
        #expect(fragments.map(\.text).joined() == original.text)
        #expect(fragments.allSatisfy { $0.id == original.id && $0.sourceID == original.sourceID && $0.locator == original.locator })
        #expect(provider.lengths.dropLast().allSatisfy { $0 == .concise })
        #expect(provider.lengths.last == .detailed)
        #expect(result.summary.sourceReferences.first?.chunkID == original.id)
        #expect(result.summary.sourceReferences == SourceReferenceResolver().resolve(chunkIDs: [original.id.uuidString], against: [original]))
    }
}
