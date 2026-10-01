import Foundation
import SwiftData

@MainActor
final class AIPresetRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func fetchPresets(for feature: AIPresetFeature? = nil) throws -> [AIPreset] {
        let descriptor = FetchDescriptor<AIPreset>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        let all = try modelContext.fetch(descriptor)
        if let feature {
            return all.filter { $0.feature == feature }
        }
        return all
    }

    @discardableResult
    func createPreset(
        name: String,
        feature: AIPresetFeature,
        basePreset: SummaryPreset? = nil,
        systemInstructions: String? = nil,
        userInstructions: String? = nil,
        provider: LLMProviderID? = nil,
        model: String? = nil,
        settings: LLMGenerationSettings? = nil
    ) throws -> AIPreset {
        let preset = AIPreset(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            feature: feature,
            basePreset: basePreset,
            systemInstructions: systemInstructions,
            userInstructions: userInstructions,
            provider: provider,
            model: model,
            settings: settings
        )
        modelContext.insert(preset)
        try modelContext.save()
        return preset
    }

    func updatePreset(
        _ preset: AIPreset,
        name: String,
        systemInstructions: String?,
        userInstructions: String?,
        provider: LLMProviderID?,
        model: String?,
        settings: LLMGenerationSettings?
    ) throws {
        preset.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        preset.systemInstructions = systemInstructions
        preset.userInstructions = userInstructions
        preset.provider = provider
        preset.model = model
        if let settings {
            preset.generationSettings = settings
        }
        preset.updatedAt = Date()
        try modelContext.save()
    }

    @discardableResult
    func duplicatePreset(_ preset: AIPreset) throws -> AIPreset {
        let duplicateName = "\(preset.name) Copy"
        let duplicate = AIPreset(
            name: duplicateName,
            feature: preset.feature,
            basePreset: preset.basePreset,
            systemInstructions: preset.systemInstructions,
            userInstructions: preset.userInstructions,
            provider: preset.provider,
            model: preset.model,
            settings: preset.generationSettings
        )
        modelContext.insert(duplicate)
        try modelContext.save()
        return duplicate
    }

    func deletePreset(_ preset: AIPreset) throws {
        modelContext.delete(preset)
        try modelContext.save()
    }
}
