import Foundation

struct SummaryConfiguration: Sendable, Equatable {
    var preset: SummaryPreset
    var customInstructions: String?
    var providerID: LLMProviderID?
    var modelName: String?
    var generationSettings: LLMGenerationSettings?
    var outputLength: OutputLength

    init(
        preset: SummaryPreset = .general,
        customInstructions: String? = nil,
        providerID: LLMProviderID? = nil,
        modelName: String? = nil,
        generationSettings: LLMGenerationSettings? = nil,
        outputLength: OutputLength = .medium
    ) {
        self.preset = preset
        self.customInstructions = customInstructions
        self.providerID = providerID
        self.modelName = modelName
        self.generationSettings = generationSettings
        self.outputLength = generationSettings?.outputLength ?? outputLength
    }
}
