import Foundation
import Testing
@testable import AudioNotes

@MainActor
struct HierarchicalSummaryGeneratorTests {
    @Test func longInputUsesChunksThenCreatesOneFinalSummary() async throws {
        let transcript = Transcript()
        transcript.segments = (0..<12).map { index in
            TranscriptSegment(position: index, startTime: Double(index * 10), endTime: Double(index * 10 + 9), text: "Section \(index) " + String(repeating: "word ", count: 100))
        }
        let provider = MockLLMProvider(delayNanoseconds: 0)
        let generator = HierarchicalSummaryGenerator(chunker: TranscriptChunker(targetCharacters: 1_000, overlapSegments: 1), singlePassLimitTokens: 100)
        var progress: [String] = []

        let result = try await generator.generate(
            transcript: transcript,
            configuration: SummaryConfiguration(preset: .meeting, outputLength: .detailed),
            provider: provider
        ) { progress.append($0) }

        #expect(result.chunkCount > 1)
        #expect(result.summary.modelName == "mock-llm-v1")
        #expect(progress.contains(where: { $0.contains("Summarizing section") }))
        #expect(progress.last == "")
    }

    @Test func shortInputStaysSinglePass() async throws {
        let transcript = Transcript()
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 1, text: "Short note.")]
        let result = try await HierarchicalSummaryGenerator(singlePassLimitTokens: 10_000).generate(
            transcript: transcript,
            configuration: SummaryConfiguration(),
            provider: MockLLMProvider(delayNanoseconds: 0)
        )
        #expect(result.chunkCount == 1)
    }

    @Test func cancellationStopsBetweenHierarchicalProviderCalls() async throws {
        let transcript = Transcript()
        transcript.segments = (0..<8).map { index in
            TranscriptSegment(position: index, startTime: Double(index), endTime: Double(index) + 0.5, text: String(repeating: "long text ", count: 200))
        }
        var wasCancelled = false
        let task = Task {
            do {
                _ = try await HierarchicalSummaryGenerator(chunker: TranscriptChunker(targetCharacters: 1_000, overlapSegments: 0), singlePassLimitTokens: 10)
                    .generate(transcript: transcript, configuration: SummaryConfiguration(), provider: MockLLMProvider(delayNanoseconds: 5_000_000_000))
            } catch is CancellationError {
                wasCancelled = true
            } catch { }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        await task.value
        #expect(wasCancelled)
    }
}
