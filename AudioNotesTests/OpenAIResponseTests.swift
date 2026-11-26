import Foundation
import Testing
@testable import AudioNotes

@MainActor
struct OpenAIResponseTests {
    static let validJSON = Data(#"{"text":"Hello world.","language":"english","duration":1.0,"segments":[{"start":0.5,"end":1.0,"text":" world."},{"start":0,"end":0.5,"text":"Hello"}]}"#.utf8)

    @Test func mapsTimestampsLanguageAndLeavesSpeakersUnknown() throws {
        let dto = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: Self.validJSON)
        let transcript = try dto.makeTranscript()
        #expect(transcript.languageCode == "en")
        #expect(!transcript.isMock)
        #expect(transcript.orderedSegments.map(\.text) == ["Hello", "world."])
        #expect(transcript.orderedSegments.map(\.startTime) == [0, 0.5])
        #expect(transcript.orderedSegments.map(\.endTime) == [0.5, 1])
        #expect(transcript.segments.allSatisfy { $0.speaker == nil })
        #expect(transcript.modelContext == nil)
    }

    @Test func rejectsMalformedAndMissingDurationResponses() throws {
        for json in ["{}", "not-json", #"{"text":"Hi","duration":1,"segments":[{"text":"Hi"}]}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: Data(json.utf8)) }
        }
        for json in [
            #"{"text":"Hi","segments":[{"text":"Hi","start":0,"end":1}]}"#,
            #"{"text":"Hi","duration":0,"segments":[{"text":"Hi","start":0,"end":1}]}"#,
            #"{"text":"Hi","duration":-5,"segments":[{"text":"Hi","start":0,"end":1}]}"#
        ] {
            let dto = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: Data(json.utf8))
            #expect(throws: OpenAITranscriptionError.invalidResponse) { try dto.makeTranscript() }
        }
    }

    @Test func sanitizesWhisperVerboseJSONQuirksInsteadOfDiscardingTranscript() throws {
        let quirkyJSON = Data(#"""
        {
          "text": "Hello world.",
          "language": "czech",
          "duration": 600.06,
          "segments": [
            {"start": 0.0, "end": 1.2, "text": "  Hello "},
            {"start": 1.2, "end": 2.5, "text": "   "},
            {"start": 29.8, "end": 0.0, "text": "world."},
            {"start": -0.2, "end": 0.4, "text": "Again"}
          ]
        }
        """#.utf8)
        let dto = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: quirkyJSON)
        let transcript = try dto.makeTranscript(modelName: "whisper-1", audioDuration: 600)
        #expect(transcript.languageCode == "cs")
        #expect(transcript.orderedSegments.map(\.position) == [0, 2, 1])
        #expect(transcript.orderedSegments.map(\.text) == ["Hello", "Again", "world."])
        #expect(transcript.orderedSegments.map(\.startTime) == [0.0, 0.0, 29.8])
        #expect(transcript.orderedSegments.map(\.endTime) == [1.2, 0.4, 29.8])

        let emptySegmentsWithText = try JSONDecoder().decode(
            OpenAITranscriptionResponse.self,
            from: Data(#"{"text":"Short utterance","duration":4.5,"segments":[]}"#.utf8)
        )
        let fallback = try emptySegmentsWithText.makeTranscript()
        #expect(fallback.orderedSegments.count == 1)
        #expect(fallback.orderedSegments.first?.text == "Short utterance")
        #expect(fallback.orderedSegments.first?.endTime == 4.5)
    }

    @Test func silenceHasUsefulError() throws {
        let dto = try JSONDecoder().decode(OpenAITranscriptionResponse.self,
                                          from: Data(#"{"text":"","duration":1,"segments":[]}"#.utf8))
        #expect(throws: OpenAITranscriptionError.noSpeech) { try dto.makeTranscript() }
    }
}
