import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct AIPresetTests {

    @Test func presetModelCreationAndSettingsRoundtrip() throws {
        let preset = AIPreset(
            name: "My Custom Meeting",
            feature: .summary,
            basePreset: .meeting,
            systemInstructions: "Act as an executive assistant.",
            userInstructions: "Focus on action items and deadlines.",
            provider: .openAI,
            model: "gpt-4o",
            settings: LLMGenerationSettings(
                maxOutputTokens: 2048,
                temperature: 0.4,
                topP: 0.9,
                reasoningEffort: .medium
            )
        )

        #expect(preset.name == "My Custom Meeting")
        #expect(preset.feature == .summary)
        #expect(preset.basePreset == .meeting)
        #expect(preset.systemInstructions == "Act as an executive assistant.")
        #expect(preset.userInstructions == "Focus on action items and deadlines.")
        #expect(preset.provider == .openAI)
        #expect(preset.model == "gpt-4o")

        let settings = preset.generationSettings
        #expect(settings.maxOutputTokens == 2048)
        #expect(settings.temperature == 0.4)
        #expect(settings.topP == 0.9)
        #expect(settings.reasoningEffort == .medium)
    }

    @Test func presetRepositoryCRUDOperations() throws {
        let schema = Schema([AIPreset.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext
        let repo = AIPresetRepository(modelContext: context)

        // 1. Create
        let created = try repo.createPreset(
            name: "Lecture Notes",
            feature: .summary,
            basePreset: .lecture,
            userInstructions: "Summarize key formulas.",
            settings: LLMGenerationSettings(temperature: 0.2)
        )
        #expect(created.name == "Lecture Notes")

        let all = try repo.fetchPresets(for: .summary)
        #expect(all.count == 1)
        #expect(all.first?.name == "Lecture Notes")

        // 2. Duplicate
        let duplicated = try repo.duplicatePreset(created)
        #expect(duplicated.name == "Lecture Notes Copy")
        #expect(duplicated.feature == .summary)
        #expect(duplicated.basePreset == .lecture)

        let afterDuplication = try repo.fetchPresets()
        #expect(afterDuplication.count == 2)

        // 3. Update
        try repo.updatePreset(
            created,
            name: "Renamed Lecture Notes",
            systemInstructions: nil,
            userInstructions: "Updated formula instructions.",
            provider: .mock,
            model: nil,
            settings: LLMGenerationSettings(temperature: 0.5)
        )
        #expect(created.name == "Renamed Lecture Notes")
        #expect(created.generationSettings.temperature == 0.5)

        // 4. Delete
        try repo.deletePreset(duplicated)
        let remaining = try repo.fetchPresets()
        #expect(remaining.count == 1)
        #expect(remaining.first?.name == "Renamed Lecture Notes")
    }
}
