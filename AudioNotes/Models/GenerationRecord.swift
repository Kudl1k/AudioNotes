import Foundation
import SwiftData

struct GenerationUsage: Codable, Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var cachedInputTokens: Int? = nil
    var reasoningTokens: Int? = nil
    var cacheWriteInputTokens: Int? = nil
    var cacheWriteDurationSeconds: Int? = nil
    var inputIncludesCachedTokens: Bool = true
    var providerSpecificUsage: [String: Int]? = nil
}

enum GenerationFeature: String, Codable, Sendable { case summary, chat, transcription }
enum GenerationStatus: String, Codable, Sendable { case succeeded, failed, cancelled, inProgress }

@Model
final class GenerationRecord {
    @Attribute(.unique) var id: UUID
    var selectedSourceIDsData: Data?
    var imageInputCount: Int = 0
    var recordingID: UUID?
    var projectID: UUID?
    var project: Project?
    var estimatedHistoryTokens: Int?
    var estimatedProjectContextTokens: Int?
    var retrievedSourceCount: Int?
    var retrievalDurationSeconds: Double?
    var firstTokenSeconds: Double?
    var featureRaw: String
    var createdAt: Date
    var startedAt: Date
    var providerIDRaw: String?
    var authenticationMethodRaw: String?
    var executionLocationRaw: String?
    var modelID: String?
    var modelDisplayNameSnapshot: String?
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

    init(recording: Recording? = nil, feature: GenerationFeature, startedAt: Date = .now,
         provider: LLMProviderID?, model: String?, presetName: String?, outputLength: OutputLength,
         settings: LLMGenerationSettings?, authenticationMethod: ProviderAuthenticationMethod? = nil,
         summaryID: UUID? = nil, status: GenerationStatus = .succeeded,
         durationSeconds: Double = 0, usage: GenerationUsage? = nil, outputText: String = "", errorCategory: String? = nil,
         generationStrategy: String = "single_pass", chunkCount: Int = 1, billingKind: BillingKind? = nil, project: Project? = nil) {
        id = UUID()
        recordingID = recording?.id
        projectID = project?.id
        self.project = project
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


extension GenerationRecord {
    func canRetry(provider: String?, model: String?, authentication: ProviderAuthenticationMethod?) -> Bool {
        statusRaw == GenerationStatus.failed.rawValue && providerIDRaw == provider && modelID == model
            && authenticationMethodRaw == authentication?.rawValue
    }
}
