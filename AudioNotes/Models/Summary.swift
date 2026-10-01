import Foundation
import SwiftData

struct KeyPoint: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

struct Decision: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var text: String
    var timestamp: TimeInterval?

    init(id: UUID = UUID(), text: String, timestamp: TimeInterval? = nil) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
    }
}

struct ActionItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var text: String
    var assignee: String?
    var dueDate: String?
    var timestamp: TimeInterval?

    init(id: UUID = UUID(), text: String, assignee: String? = nil,
         dueDate: String? = nil, timestamp: TimeInterval? = nil) {
        self.id = id
        self.text = text
        self.assignee = assignee
        self.dueDate = dueDate
        self.timestamp = timestamp
    }
}

struct OpenQuestion: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var text: String
    var timestamp: TimeInterval?

    init(id: UUID = UUID(), text: String, timestamp: TimeInterval? = nil) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
    }
}

struct ImportantQuote: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var text: String
    var speaker: String?
    var timestamp: TimeInterval?

    init(id: UUID = UUID(), text: String, speaker: String? = nil, timestamp: TimeInterval? = nil) {
        self.id = id
        self.text = text
        self.speaker = speaker
        self.timestamp = timestamp
    }
}

struct SummarySection: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var items: [String]

    init(id: UUID = UUID(), title: String, items: [String] = []) {
        self.id = id
        self.title = title
        self.items = items
    }
}

@Model
final class Summary {
    @Attribute(.unique) var id: UUID
    var title: String = ""
    var text: String
    var overview: String
    var presetRaw: String
    var providerName: String
    var modelName: String
    var outputLengthRaw: String = OutputLength.medium.rawValue
    var keyPoints: [KeyPoint]
    var decisions: [Decision]
    var actionItems: [ActionItem]
    var openQuestions: [OpenQuestion]
    var importantQuotes: [ImportantQuote]
    var additionalSections: [SummarySection]
    var createdAt: Date
    var updatedAt: Date
    var recording: Recording?
    var historicalRecording: Recording?
    var sourceReferencesData: Data?
    var sourceReferences: [SourceReference] {
        get { sourceReferencesData.flatMap { try? JSONDecoder().decode([SourceReference].self, from: $0) } ?? [] }
        set { sourceReferencesData = try? JSONEncoder().encode(newValue) }
    }
    var generationID: UUID?
    var reportedUsageData: Data?

    var reportedUsage: GenerationUsage? {
        get { reportedUsageData.flatMap { try? JSONDecoder().decode(GenerationUsage.self, from: $0) } }
        set { reportedUsageData = try? JSONEncoder().encode(newValue) }
    }

    var preset: SummaryPreset {
        get { SummaryPreset(rawValue: presetRaw) ?? .general }
        set { presetRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        overview: String = "",
        preset: SummaryPreset = .general,
        providerName: String = "",
        modelName: String = "",
        keyPoints: [KeyPoint] = [],
        decisions: [Decision] = [],
        actionItems: [ActionItem] = [],
        openQuestions: [OpenQuestion] = [],
        importantQuotes: [ImportantQuote] = [],
        additionalSections: [SummarySection] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        text: String = "",
        outputLength: OutputLength = .medium,
        title: String = ""
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveOverview = overview.isEmpty ? text : overview
        let effectiveText = text.isEmpty ? effectiveOverview : text
        self.overview = effectiveOverview
        self.presetRaw = preset.rawValue
        self.providerName = providerName
        self.modelName = modelName
        self.outputLengthRaw = outputLength.rawValue
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.importantQuotes = importantQuotes
        self.additionalSections = additionalSections
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.text = effectiveText
    }

    var outputLength: OutputLength {
        get { OutputLength(rawValue: outputLengthRaw) ?? .medium }
        set { outputLengthRaw = newValue.rawValue }
    }
}
