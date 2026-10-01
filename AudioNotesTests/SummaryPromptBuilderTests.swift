import Foundation
import Testing
@testable import AudioNotes

@MainActor
struct SummaryPromptBuilderTests {
    @Test(arguments: OutputLength.allCases)
    func outputLengthInstructionIsPresentAndDistinct(_ length: OutputLength) throws {
        let transcript = Transcript()
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 1, text: "Content")]
        let context = try SummaryPromptBuilder().formatTranscript(transcript)
        let prompt = SummaryPromptBuilder().buildPrompt(
            transcriptContext: context,
            configuration: SummaryConfiguration(outputLength: length)
        )
        #expect(prompt.systemMessage.contains(OutputLengthInstructionBuilder.instruction(for: length)))
        #expect(prompt.systemMessage.contains(SummaryPromptBuilder.titleInstruction))
        let sourcePrompt = try SourceSummaryContext(chunks: []).prompt(configuration: SummaryConfiguration(outputLength: length))
        #expect(sourcePrompt.systemMessage.contains(SummaryPromptBuilder.titleInstruction))
    }

    @Test func formatsSegmentsChronologicallyWithTimestampsAndSpeakers() throws {
        let transcript = Transcript()
        let seg1 = TranscriptSegment(position: 1, startTime: 10, endTime: 25, text: "Second segment")
        seg1.speaker = "Alice"
        let seg0 = TranscriptSegment(position: 0, startTime: 0, endTime: 5, text: "First segment")
        seg0.speaker = "Bob"
        transcript.segments = [seg1, seg0]

        let builder = SummaryPromptBuilder()
        let context = try builder.formatTranscript(transcript)

        #expect(context.segmentCount == 2)
        #expect(context.approximateTokens > 0)
        #expect(context.text.contains("[00:00 - 00:05] Bob:"))
        #expect(context.text.contains("First segment"))
        #expect(context.text.contains("[00:10 - 00:25] Alice:"))
        #expect(context.text.contains("Second segment"))

        // Ensure chronological ordering: seg0 should appear before seg1
        let firstRange = try #require(context.text.range(of: "First segment"))
        let secondRange = try #require(context.text.range(of: "Second segment"))
        #expect(firstRange.lowerBound < secondRange.lowerBound)
    }

    @Test func rejectsEmptyTranscript() {
        let transcript = Transcript()
        let builder = SummaryPromptBuilder()
        #expect(throws: LLMError.self) {
            try builder.formatTranscript(transcript)
        }
    }

    @Test func buildsPromptWithPresetAndCustomInstructions() throws {
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Discussing roadmaps.")
        ]

        let builder = SummaryPromptBuilder()
        let context = try builder.formatTranscript(transcript)

        let configMeeting = SummaryConfiguration(preset: .meeting)
        let promptMeeting = builder.buildPrompt(transcriptContext: context, configuration: configMeeting)
        #expect(promptMeeting.systemMessage.contains("MEETING"))
        #expect(promptMeeting.systemMessage.contains(SummaryPreset.meeting.systemInstructions))
        #expect(promptMeeting.userMessage.contains("Discussing roadmaps."))

        let configCustom = SummaryConfiguration(preset: .custom, customInstructions: "Focus exclusively on security vulnerabilities.")
        let promptCustom = builder.buildPrompt(transcriptContext: context, configuration: configCustom)
        #expect(promptCustom.systemMessage.contains("ADDITIONAL USER INSTRUCTIONS:"))
        #expect(promptCustom.systemMessage.contains("Focus exclusively on security vulnerabilities."))
    }
}
