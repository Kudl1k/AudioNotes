import Foundation
import Testing
@testable import AudioNotes

@MainActor
struct OpenAILLMProviderTests {
    @Test func missingKeyThrowsMissingAPIKey() async {
        let store = MockCredentialStore()
        let provider = OpenAILLMProvider(credentials: store)
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 5, text: "Sample audio")
        ]

        await #expect(throws: LLMError.missingAPIKey) {
            _ = try await provider.generateSummary(
                transcript: transcript,
                configuration: SummaryConfiguration(preset: .general)
            )
        }
    }

    @Test func mapsUnauthorizedToInvalidAuthentication() async throws {
        let store = MockCredentialStore(key: "invalid-key")
        let errorBody = Data(#"{"error": {"message": "Invalid API key", "type": "invalid_request_error"}}"#.utf8)
        let fixture = OpenAINetworkFixture(status: 401, data: errorBody)
        defer { fixture.cleanUp() }

        let client = OpenAILLMClient(session: fixture.session)
        let provider = OpenAILLMProvider(credentials: store, client: client)

        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 5, text: "Sample audio")
        ]

        await #expect(throws: LLMError.invalidAuthentication) {
            _ = try await provider.generateSummary(
                transcript: transcript,
                configuration: SummaryConfiguration(preset: .general)
            )
        }
    }

    @Test func mapsCreditBalanceExhausted() async throws {
        let store = MockCredentialStore(key: "test-key")
        let errorBody = Data(#"{"error": {"code": "credit_balance_exhausted", "message": "Balance empty"}}"#.utf8)
        let fixture = OpenAINetworkFixture(status: 429, data: errorBody)
        defer { fixture.cleanUp() }

        let client = OpenAILLMClient(session: fixture.session)
        let provider = OpenAILLMProvider(credentials: store, client: client)

        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 5, text: "Sample audio")
        ]

        await #expect(throws: LLMError.creditBalanceExhausted) {
            _ = try await provider.generateSummary(
                transcript: transcript,
                configuration: SummaryConfiguration(preset: .general)
            )
        }
    }

    @Test func handlesSuccessfulGeneration() async throws {
        let store = MockCredentialStore(key: "test-key")
        let responseJson = """
        {
            "id": "chatcmpl-test",
            "choices": [
                {
                    "message": {
                        "role": "assistant",
                        "content": "{\\"overview\\": \\"Cloud summary\\", \\"keyPoints\\": [\\"Done\\"], \\"decisions\\": [], \\"actionItems\\": [], \\"openQuestions\\": [], \\"importantQuotes\\": [], \\"additionalSections\\": []}"
                    },
                    "finish_reason": "stop"
                }
            ]
        }
        """
        let fixture = OpenAINetworkFixture(status: 200, data: Data(responseJson.utf8))
        defer { fixture.cleanUp() }

        let client = OpenAILLMClient(session: fixture.session)
        let provider = OpenAILLMProvider(credentials: store, client: client)

        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 5, text: "Sample audio")
        ]

        let summary = try await provider.generateSummary(
            transcript: transcript,
            configuration: SummaryConfiguration(preset: .meeting)
        )

        #expect(summary.overview == "Cloud summary")
        #expect(summary.preset == SummaryPreset.meeting)
        #expect(summary.keyPoints.first?.text == "Done")
    }
}
