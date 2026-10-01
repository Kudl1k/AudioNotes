import Foundation
import Testing
@testable import AudioNotes

@MainActor
struct OpenAISummaryDTOTests {
    @Test func decodesStructuredResponseAndMapsToDomainSummary() throws {
        let json = """
        {
            "title": "  Staging Deployment and Testing  ",
            "overview": "Overview of meeting",
            "keyPoints": ["Point 1", "Point 2"],
            "decisions": [
                { "text": "Deploy to staging", "timestampSeconds": 42.5 }
            ],
            "actionItems": [
                { "text": "Write unit tests", "assignee": "Alice", "dueDate": "Friday", "timestampSeconds": 50.0 }
            ],
            "openQuestions": [
                { "text": "Who manages the keys?", "timestampSeconds": null }
            ],
            "importantQuotes": [
                { "text": "Ship early, ship often", "speaker": "Bob", "timestampSeconds": 12.0 }
            ],
            "additionalSections": [
                { "title": "Next Steps", "items": ["Item A", "Item B"] }
            ]
        }
        """

        let data = try #require(json.data(using: .utf8))
        let dto = try JSONDecoder().decode(OpenAISummaryResponseDTO.self, from: data)

        #expect(dto.overview == "Overview of meeting")
        #expect(dto.keyPoints.count == 2)
        #expect(dto.decisions.count == 1)
        #expect(dto.decisions.first?.timestampSeconds == 42.5)
        #expect(dto.actionItems.first?.assignee == "Alice")
        #expect(dto.openQuestions.first?.timestampSeconds == nil)
        #expect(dto.importantQuotes.first?.speaker == "Bob")
        #expect(dto.additionalSections.first?.title == "Next Steps")

        let domainSummary = dto.makeSummary(
            preset: .meeting,
            providerName: "OpenAI",
            modelName: "gpt-4o-mini"
        )

        #expect(domainSummary.overview == "Overview of meeting")
        #expect(domainSummary.title == "Staging Deployment and Testing")
        #expect(domainSummary.preset == .meeting)
        #expect(domainSummary.providerName == "OpenAI")
        #expect(domainSummary.modelName == "gpt-4o-mini")
        #expect(domainSummary.keyPoints.count == 2)
        #expect(domainSummary.decisions.first?.text == "Deploy to staging")
        #expect(domainSummary.decisions.first?.timestamp == 42.5)
        #expect(domainSummary.actionItems.first?.assignee == "Alice")
        #expect(domainSummary.actionItems.first?.dueDate == "Friday")
        #expect(domainSummary.openQuestions.first?.timestamp == nil)
        #expect(domainSummary.importantQuotes.first?.speaker == "Bob")
        #expect(domainSummary.additionalSections.first?.title == "Next Steps")
        #expect(domainSummary.additionalSections.first?.items == ["Item A", "Item B"])
    }

    @Test func encodesRequestWithStrictJSONSchema() throws {
        let request = OpenAILLMRequestDTO(
            model: "gpt-4o-mini",
            messages: [
                OpenAIChatMessage(role: "system", content: "System message"),
                OpenAIChatMessage(role: "user", content: "User transcript")
            ]
        )

        let data = try request.encodeToData()
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["model"] as? String == "gpt-4o-mini")
        let responseFormat = object?["response_format"] as? [String: Any]
        #expect(responseFormat?["type"] as? String == "json_schema")
        let jsonSchema = responseFormat?["json_schema"] as? [String: Any]
        #expect(jsonSchema?["strict"] as? Bool == true)
        #expect(jsonSchema?["name"] as? String == "summary_response")
        let schema = try #require(jsonSchema?["schema"] as? [String: Any])
        #expect((schema["required"] as? [String])?.contains("title") == true)
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect((properties["title"] as? [String: Any])?["type"] as? String == "string")
    }

    @Test func legacyResponseWithoutTitleStillDecodes() throws {
        let json = #"{"overview":"Legacy summary","keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[],"importantQuotes":[],"additionalSections":[]}"#
        let dto = try JSONDecoder().decode(StructuredSummaryResponse.self, from: Data(json.utf8))
        #expect(dto.makeSummary(preset: .general, providerName: "Legacy", modelName: "").title.isEmpty)
    }
}
