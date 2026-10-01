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

    @Test func rejectsMalformedAndInvalidResponses() throws {
        for json in ["{}", "not-json", #"{"text":"Hi","duration":1,"segments":[{"text":"Hi"}]}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: Data(json.utf8)) }
        }
        for json in [
            #"{"text":"Hi","duration":1,"segments":[]}"#,
            #"{"text":"Hi","duration":1,"segments":[{"text":"Hi","start":-1,"end":1}]}"#,
            #"{"text":"Hi","duration":1,"segments":[{"text":"Hi","start":1,"end":0}]}"#
        ] {
            let dto = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: Data(json.utf8))
            #expect(throws: OpenAITranscriptionError.invalidResponse) { try dto.makeTranscript() }
        }
    }

    @Test func silenceHasUsefulError() throws {
        let dto = try JSONDecoder().decode(OpenAITranscriptionResponse.self,
                                          from: Data(#"{"text":"","duration":1,"segments":[]}"#.utf8))
        #expect(throws: OpenAITranscriptionError.noSpeech) { try dto.makeTranscript() }
    }
}
