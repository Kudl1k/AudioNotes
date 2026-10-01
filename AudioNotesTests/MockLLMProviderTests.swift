import Foundation
import Testing
@testable import AudioNotes

@MainActor
struct MockLLMProviderTests {
    @Test func generatesPresetSpecificSummary() async throws {
        let provider = MockLLMProvider(delayNanoseconds: 0)
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Lecture on AI systems"),
            TranscriptSegment(position: 1, startTime: 10, endTime: 25, text: "Explaining LLM providers")
        ]

        let summary = try await provider.generateSummary(
            transcript: transcript,
            configuration: SummaryConfiguration(preset: .lecture)
        )

        #expect(summary.preset == .lecture)
        #expect(!summary.overview.isEmpty)
        #expect(!summary.keyPoints.isEmpty)
        #expect(!summary.decisions.isEmpty)
        #expect(!summary.actionItems.isEmpty)
        #expect(summary.additionalSections.contains { $0.title == "Main Concepts" })
        #expect(summary.additionalSections.contains { $0.title == "Study Notes" })
    }

    @Test func rejectsEmptyTranscript() async {
        let provider = MockLLMProvider(delayNanoseconds: 0)
        let transcript = Transcript()
        await #expect(throws: LLMError.self) {
            _ = try await provider.generateSummary(
                transcript: transcript,
                configuration: SummaryConfiguration(preset: .general)
            )
        }
    }

    @Test func handlesCancellation() async throws {
        let provider = MockLLMProvider(delayNanoseconds: 1_000_000_000)
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Cancellation test")
        ]

        let task = Task { @MainActor in
            _ = try await provider.generateSummary(
                transcript: transcript,
                configuration: SummaryConfiguration(preset: .general)
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
