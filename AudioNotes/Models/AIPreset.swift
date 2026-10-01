import Foundation
import SwiftData

enum AIPresetFeature: String, Codable, CaseIterable, Sendable {
    case summary
    case chat
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
