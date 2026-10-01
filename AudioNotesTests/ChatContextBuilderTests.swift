import Foundation
import Testing
@testable import AudioNotes

@Suite struct ChatContextBuilderTests {

    @Test func formatsTranscriptAndMetadataIntoPrompt() throws {
        let transcript = Transcript()
        let seg = TranscriptSegment(position: 0, startTime: 0.0, endTime: 5.0, text: "Welcome to the meeting.", speaker: "Host")
        transcript.segments = [seg]

        let context = ChatContext(
            recordingTitle: "Standup Notes",
            transcript: transcript,
            summary: nil
        )

        let builder = ChatContextBuilder()
        let messages = [LLMChatMessage(role: .user, content: "What was discussed?")]
        let prompt = try builder.buildPrompt(context: context, history: messages)

        #expect(prompt.systemInstructions.contains("<recording_metadata>"))
        #expect(prompt.systemInstructions.contains("Standup Notes"))
        #expect(prompt.systemInstructions.contains("<transcript>"))
        #expect(prompt.systemInstructions.contains(seg.id.uuidString))
        #expect(prompt.systemInstructions.contains("Host"))
        #expect(prompt.systemInstructions.contains("Welcome to the meeting."))
        #expect(!prompt.systemInstructions.contains("<summary>"))
        #expect(prompt.messages.count == 1)
        #expect(prompt.messages[0].content == "What was discussed?")
    }

    @Test func includesSummaryWhenProvided() throws {
        let transcript = Transcript()
        let seg = TranscriptSegment(position: 0, startTime: 0.0, endTime: 12.0, text: "Roadmap discussion.")
        transcript.segments = [seg]

        let summary = Summary(
            overview: "Overview of Q4 roadmap",
            keyPoints: [KeyPoint(text: "Ship Milestone 5")],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            importantQuotes: [],
            additionalSections: []
        )

        let context = ChatContext(
            recordingTitle: "Planning",
            transcript: transcript,
            summary: summary
        )

        let builder = ChatContextBuilder()
        let prompt = try builder.buildPrompt(context: context, history: [LLMChatMessage(role: .user, content: "Tell me more")])

        #expect(prompt.systemInstructions.contains("<summary>"))
        #expect(prompt.systemInstructions.contains("Overview of Q4 roadmap"))
        #expect(prompt.systemInstructions.contains("Ship Milestone 5"))
    }

    @Test func throwsWhenTranscriptIsEmpty() {
        let transcript = Transcript()
        transcript.segments = []

        let context = ChatContext(
            recordingTitle: "Empty Recording",
            transcript: transcript,
            summary: nil
        )

        let builder = ChatContextBuilder()
        #expect(throws: LLMError.transcriptEmpty) {
            _ = try builder.buildPrompt(context: context, history: [LLMChatMessage(role: .user, content: "Hello")])
        }
    }

    @Test func throwsWhenContextExceedsTokenLimit() {
        let hugeText = String(repeating: "Extremely long discussion text filling context window. ", count: 12000)
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0.0, endTime: 1000.0, text: hugeText)
        ]

        let context = ChatContext(
            recordingTitle: "Huge Note",
            transcript: transcript,
            summary: nil
        )

        let builder = ChatContextBuilder()
        #expect {
            _ = try builder.buildPrompt(context: context, history: [LLMChatMessage(role: .user, content: "Summarize")])
        } throws: { error in
            guard case LLMError.contextTooLarge = error else { return false }
            return true
        }
    }
}
