import Foundation
import SwiftData
@testable import AudioNotes

/// Frozen pre-M9 model fixture for on-disk lightweight-migration tests.
enum LegacyM8Schema {
@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var title: String
    var importedAt: Date
    /// A relative filename keeps the library portable across sandbox locations.
    var audioFileName: String
    var originalFileName: String
    var duration: TimeInterval

    @Relationship(deleteRule: .cascade, inverse: \Transcript.recording)
    var transcript: Transcript?
    @Relationship(deleteRule: .cascade, inverse: \Summary.recording)
    var summary: Summary?
    @Relationship(deleteRule: .cascade, inverse: \Summary.historicalRecording)
    var summaryHistory: [Summary] = []
    @Relationship(deleteRule: .cascade, inverse: \GenerationRecord.recording)
    var generationRecords: [GenerationRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \ChatSession.recording)
    var chatSessions: [ChatSession] = []


    init(id: UUID = UUID(), title: String, audioFileName: String,
         originalFileName: String, duration: TimeInterval, importedAt: Date = .now) {
        self.id = id
        self.title = title
        self.audioFileName = audioFileName
        self.originalFileName = originalFileName
        self.duration = duration
        self.importedAt = importedAt
    }
}

@Model
final class Transcript {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var languageCode: String?
    var sourceName: String?
    var isMock: Bool = false
    var recording: Recording?
    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.transcript)
    var segments: [TranscriptSegment] = []

    var orderedSegments: [TranscriptSegment] {
        segments.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    init(id: UUID = UUID(), languageCode: String? = nil, createdAt: Date = .now,
         sourceName: String? = nil, isMock: Bool = false) {
        self.id = id
        self.languageCode = languageCode
        self.createdAt = createdAt
        self.sourceName = sourceName
        self.isMock = isMock
    }
}

@Model
final class TranscriptSegment {
    @Attribute(.unique) var id: UUID
    var position: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speaker: String?
    var transcript: Transcript?

    init(id: UUID = UUID(), position: Int, startTime: TimeInterval,
         endTime: TimeInterval, text: String, speaker: String? = nil) {
        self.id = id
        self.position = position
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
    }
}

@Model
final class Summary {
    @Attribute(.unique) var id: UUID
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
        outputLength: OutputLength = .medium
    ) {
        self.id = id
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

@Model
final class ChatSession {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var recording: Recording?
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage] = []

    var orderedMessages: [ChatMessage] {
        messages.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    init(
        id: UUID = UUID(),
        title: String = "Chat",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var role: ChatRole
    var text: String
    var createdAt: Date
    var statusRaw: String = ChatMessageStatus.completed.rawValue
    var references: [TranscriptReference] = []
    var session: ChatSession?
    var generationID: UUID?

    var content: String {
        get { text }
        set { text = newValue }
    }

    var status: ChatMessageStatus {
        get { ChatMessageStatus(rawValue: statusRaw) ?? .completed }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        createdAt: Date = .now,
        status: ChatMessageStatus = .completed,
        references: [TranscriptReference] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.statusRaw = status.rawValue
        self.references = references
    }
}

@Model
final class AIPreset {
    @Attribute(.unique) var id: UUID
    var name: String
    var featureRaw: String
    var basePresetRaw: String?
    var systemInstructions: String?
    var userInstructions: String?
    var providerRaw: String?
    var model: String?
    var maxOutputTokens: Int?
    var temperature: Double?
    var topP: Double?
    var reasoningEffortRaw: String?
    var outputLengthRaw: String = OutputLength.medium.rawValue
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        feature: AIPresetFeature,
        basePreset: SummaryPreset? = nil,
        systemInstructions: String? = nil,
        userInstructions: String? = nil,
        provider: LLMProviderID? = nil,
        model: String? = nil,
        settings: LLMGenerationSettings? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.featureRaw = feature.rawValue
        self.basePresetRaw = basePreset?.rawValue
        self.systemInstructions = systemInstructions
        self.userInstructions = userInstructions
        self.providerRaw = provider?.rawValue
        self.model = model
        self.maxOutputTokens = settings?.maxOutputTokens
        self.temperature = settings?.temperature
        self.topP = settings?.topP
        self.reasoningEffortRaw = settings?.reasoningEffort?.rawValue
        self.outputLengthRaw = settings?.outputLength.rawValue ?? OutputLength.medium.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var feature: AIPresetFeature {
        get { AIPresetFeature(rawValue: featureRaw) ?? .summary }
        set { featureRaw = newValue.rawValue }
    }

    var basePreset: SummaryPreset? {
        get { basePresetRaw.flatMap { SummaryPreset(rawValue: $0) } }
        set { basePresetRaw = newValue?.rawValue }
    }

    var provider: LLMProviderID? {
        get { providerRaw.flatMap { LLMProviderID(rawValue: $0) } }
        set { providerRaw = newValue?.rawValue }
    }

    var reasoningEffort: ReasoningEffort? {
        get { reasoningEffortRaw.flatMap { ReasoningEffort(rawValue: $0) } }
        set { reasoningEffortRaw = newValue?.rawValue }
    }

    var generationSettings: LLMGenerationSettings {
        get {
            LLMGenerationSettings(
                maxOutputTokens: maxOutputTokens,
                temperature: temperature,
                topP: topP,
                reasoningEffort: reasoningEffort,
                outputLength: OutputLength(rawValue: outputLengthRaw) ?? .medium
            )
        }
        set {
            maxOutputTokens = newValue.maxOutputTokens
            temperature = newValue.temperature
            topP = newValue.topP
            reasoningEffortRaw = newValue.reasoningEffort?.rawValue
            outputLengthRaw = newValue.outputLength.rawValue
        }
    }
}

@Model
final class GenerationRecord {
    @Attribute(.unique) var id: UUID
    var recordingID: UUID
    var featureRaw: String
    var createdAt: Date
    var startedAt: Date
    var providerIDRaw: String?
    var authenticationMethodRaw: String?
    var modelID: String?
    var presetName: String?
    var outputLengthRaw: String
    var maxOutputTokens: Int?
    var temperature: Double?
    var topP: Double?
    var reasoningEffortRaw: String?
    var statusRaw: String
    var durationSeconds: Double
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var characterCount: Int
    var wordCount: Int
    var errorCategory: String?
    var generationStrategy: String = "single_pass"
    var chunkCount: Int = 1
    var attemptCount: Int = 1
    var summaryID: UUID?
    var recording: Recording?
    var requestUsageData: Data?
    var costData: Data?
    var billingKindRaw: String?
    var estimatedCostData: Data?
    var estimatedCostRangeData: Data?
    var chatMessageID: UUID?

    var requests: [RequestUsageRecord] {
        get { requestUsageData.flatMap { try? JSONDecoder().decode([RequestUsageRecord].self, from: $0) } ?? [] }
        set { requestUsageData = try? JSONEncoder().encode(newValue) }
    }
    var billingKind: BillingKind {
        billingKindRaw.flatMap(BillingKind.init(rawValue:)) ?? BillingKind.resolve(provider: providerIDRaw,
            authentication: authenticationMethodRaw.flatMap(ProviderAuthenticationMethod.init(rawValue:)))
    }

    var usageCost: UsageCost {
        get { costData.flatMap { try? JSONDecoder().decode(UsageCost.self, from: $0) }
            ?? UsageCost(amount: nil, billingKind: .unknown, status: .unavailable) }
        set { costData = try? JSONEncoder().encode(newValue) }
    }

    func updateCost() {
        let entries = requests
        inputTokens = entries.allSatisfy { $0.usage?.inputTokens != nil } ? entries.compactMap { $0.usage?.inputTokens }.reduce(0, +) : nil
        outputTokens = entries.allSatisfy { $0.usage?.outputTokens != nil } ? entries.compactMap { $0.usage?.outputTokens }.reduce(0, +) : nil
        totalTokens = entries.allSatisfy { $0.usage?.totalTokens != nil } ? entries.compactMap { $0.usage?.totalTokens }.reduce(0, +) : nil
        if entries.isEmpty { inputTokens = nil; outputTokens = nil; totalTokens = nil }
        usageCost = UsageAggregation.cost(entries.map(\.cost), billing: billingKind)
    }

    init(recording: Recording, feature: GenerationFeature, startedAt: Date = .now,
         provider: LLMProviderID?, model: String?, presetName: String?, outputLength: OutputLength,
         settings: LLMGenerationSettings?, authenticationMethod: ProviderAuthenticationMethod? = nil,
         summaryID: UUID? = nil, status: GenerationStatus = .succeeded,
         durationSeconds: Double = 0, usage: GenerationUsage? = nil, outputText: String = "", errorCategory: String? = nil,
         generationStrategy: String = "single_pass", chunkCount: Int = 1, billingKind: BillingKind? = nil) {
        id = UUID()
        recordingID = recording.id
        featureRaw = feature.rawValue
        createdAt = .now
        self.startedAt = startedAt
        providerIDRaw = provider?.rawValue
        authenticationMethodRaw = authenticationMethod?.rawValue
        billingKindRaw = (billingKind ?? BillingKind.resolve(provider: provider?.rawValue, authentication: authenticationMethod)).rawValue
        modelID = model
        self.presetName = presetName
        outputLengthRaw = outputLength.rawValue
        maxOutputTokens = settings?.maxOutputTokens
        temperature = settings?.temperature
        topP = settings?.topP
        reasoningEffortRaw = settings?.reasoningEffort?.rawValue
        statusRaw = status.rawValue
        self.durationSeconds = durationSeconds
        inputTokens = usage?.inputTokens
        outputTokens = usage?.outputTokens
        totalTokens = usage?.totalTokens
        characterCount = outputText.count
        wordCount = outputText.split(whereSeparator: \.isWhitespace).count
        self.errorCategory = errorCategory
        self.generationStrategy = generationStrategy
        self.chunkCount = max(1, chunkCount)
        self.summaryID = summaryID
        self.recording = recording
    }
}


}
