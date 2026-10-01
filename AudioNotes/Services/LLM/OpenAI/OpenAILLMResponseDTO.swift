import Foundation

struct OpenAIDecisionDTO: Codable, Sendable, Equatable {
    let text: String
    let timestampSeconds: Double?

    init(text: String, timestampSeconds: Double? = nil) {
        self.text = text
        self.timestampSeconds = timestampSeconds
    }
}

struct OpenAIActionItemDTO: Codable, Sendable, Equatable {
    let text: String
    let assignee: String?
    let dueDate: String?
    let timestampSeconds: Double?

    init(text: String, assignee: String? = nil, dueDate: String? = nil, timestampSeconds: Double? = nil) {
        self.text = text
        self.assignee = assignee
        self.dueDate = dueDate
        self.timestampSeconds = timestampSeconds
    }
}

struct OpenAIOpenQuestionDTO: Codable, Sendable, Equatable {
    let text: String
    let timestampSeconds: Double?

    init(text: String, timestampSeconds: Double? = nil) {
        self.text = text
        self.timestampSeconds = timestampSeconds
    }
}

struct OpenAIImportantQuoteDTO: Codable, Sendable, Equatable {
    let text: String
    let speaker: String?
    let timestampSeconds: Double?

    init(text: String, speaker: String? = nil, timestampSeconds: Double? = nil) {
        self.text = text
        self.speaker = speaker
        self.timestampSeconds = timestampSeconds
    }
}

struct OpenAISummarySectionDTO: Codable, Sendable, Equatable {
    let title: String
    let items: [String]

    init(title: String, items: [String] = []) {
        self.title = title
        self.items = items
    }
}

struct StructuredSummaryResponse: Codable, Sendable, Equatable {
    var title: String? = nil
    var referenceChunkIDs: [String]? = nil
    var reportedUsage: GenerationUsage? = nil
    let overview: String
    let keyPoints: [String]
    let decisions: [OpenAIDecisionDTO]
    let actionItems: [OpenAIActionItemDTO]
    let openQuestions: [OpenAIOpenQuestionDTO]
    let importantQuotes: [OpenAIImportantQuoteDTO]
    let additionalSections: [OpenAISummarySectionDTO]

    init(
        overview: String,
        keyPoints: [String] = [],
        decisions: [OpenAIDecisionDTO] = [],
        actionItems: [OpenAIActionItemDTO] = [],
        openQuestions: [OpenAIOpenQuestionDTO] = [],
        importantQuotes: [OpenAIImportantQuoteDTO] = [],
        additionalSections: [OpenAISummarySectionDTO] = [],
        title: String? = nil
    ) {
        self.overview = overview
        self.title = title
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.importantQuotes = importantQuotes
        self.additionalSections = additionalSections
    }

    @MainActor
    func makeSummary(
        preset: SummaryPreset,
        providerName: String,
        modelName: String
    ) -> Summary {
        let mappedKeyPoints = keyPoints.map { KeyPoint(text: $0) }
        let mappedDecisions = decisions.map { Decision(text: $0.text, timestamp: $0.timestampSeconds) }
        let mappedActionItems = actionItems.map {
            ActionItem(text: $0.text, assignee: $0.assignee, dueDate: $0.dueDate, timestamp: $0.timestampSeconds)
        }
        let mappedQuestions = openQuestions.map { OpenQuestion(text: $0.text, timestamp: $0.timestampSeconds) }
        let mappedQuotes = importantQuotes.map {
            ImportantQuote(text: $0.text, speaker: $0.speaker, timestamp: $0.timestampSeconds)
        }
        let mappedSections = additionalSections.map {
            SummarySection(title: $0.title, items: $0.items)
        }

        return Summary(
            overview: overview,
            preset: preset,
            providerName: providerName,
            modelName: modelName,
            keyPoints: mappedKeyPoints,
            decisions: mappedDecisions,
            actionItems: mappedActionItems,
            openQuestions: mappedQuestions,
            importantQuotes: mappedQuotes,
            additionalSections: mappedSections,
            title: title ?? ""
        )
    }
}

// Compatibility name for the OpenAI transport and existing fixtures.
typealias OpenAISummaryResponseDTO = StructuredSummaryResponse
