import Foundation
import Testing
@testable import AudioNotes

@Suite struct ChatStreamingParserTests {

    @Test func parsesStreamingAnswerAcrossChunks() {
        let parser = StreamingJSONAnswerParser()
        let chunks = [
            "{\"ans",
            "wer\": \"Hello ",
            "world! This is a ",
            "test.\", \"reference",
            "SegmentIDs\": []}"
        ]

        var emitted = ""
        for chunk in chunks {
            if let delta = parser.append(chunk: chunk) {
                emitted.append(delta)
            }
        }

        let result = parser.finish()
        #expect(emitted == "Hello world! This is a test.")
        #expect(result.answer == "Hello world! This is a test.")
        #expect(result.referenceSegmentIDs.isEmpty)
    }

    @Test func handlesEscapedCharactersAndSplitEscapes() {
        let parser = StreamingJSONAnswerParser()
        // Chunk split right in the middle of \n
        let chunks = [
            "{\"answer\": \"Line 1\\",
            "nLine 2 with \\\"quotes\\\" and backslash \\\\.\", \"referenceSegmentIDs\": []}"
        ]

        var emitted = ""
        for chunk in chunks {
            if let delta = parser.append(chunk: chunk) {
                emitted.append(delta)
            }
        }

        let result = parser.finish()
        #expect(emitted == "Line 1\nLine 2 with \"quotes\" and backslash \\.")
        #expect(result.answer == "Line 1\nLine 2 with \"quotes\" and backslash \\.")
    }

    @Test func extractsValidReferenceUUIDs() {
        let parser = StreamingJSONAnswerParser()
        let id1 = UUID()
        let id2 = UUID()

        let json = """
        {"answer": "Discussion was held.", "referenceSegmentIDs": ["\(id1.uuidString)", "invalid-uuid", "\(id2.uuidString)"]}
        """

        _ = parser.append(chunk: json)
        let result = parser.finish()

        #expect(result.answer == "Discussion was held.")
        #expect(result.referenceSegmentIDs == [id1.uuidString, "invalid-uuid", id2.uuidString])
    }

    @Test func handlesEmptyAndWhitespacePayload() {
        let parser = StreamingJSONAnswerParser()
        let delta = parser.append(chunk: "")
        #expect(delta == nil)

        let result = parser.finish()
        #expect(result.answer.isEmpty)
        #expect(result.referenceSegmentIDs.isEmpty)
    }
}
