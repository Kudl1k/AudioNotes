import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct GenerationProviderSelectionTests {
    @Test func transcriptionOverridesPreserveDefaultsAndLanguage() throws {
        let name = "GenerationSelection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = TranscriptionConfiguration(defaults: defaults)
        configuration.language = .czech
        let resolver = TranscriptionProviderResolver(configuration: configuration, credentials: MockCredentialStore())
        let selected = try #require((resolver.resolve(provider: .openAI, model: "gpt-4o-mini-transcribe") as? PrivacyTranscriptionProvider)?.base as? OpenAITranscriptionProvider)
        #expect(selected.configuration.model == .gpt4oMiniTranscribe)
        #expect(selected.configuration.language == .czech)
        #expect(configuration.selectedProvider == .mock)
        #expect(configuration.openAIModel == .whisper1)
        #expect(resolver.resolve().isMock)
        #expect(resolver.models(for: .openAI).contains { $0.id == "whisper-1" })
    }

    @Test func summaryOverridesPreserveIndependentDefaults() throws {
        let name = "GenerationSelection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = LLMConfiguration(defaults: defaults)
        configuration.summaryAuthMethod = .apiKey
        let resolver = LLMProviderResolver(configuration: configuration, credentials: MockCredentialStore())
        let selected = resolver.resolveSummary(provider: .openAI, model: "gpt-4o")
        #expect(selected.id == .openAI)
        #expect(selected.modelID == "gpt-4o")
        #expect(configuration.summaryProvider == .mock)
        #expect(configuration.summaryOpenAIModel == .gpt4oMini)
        #expect(resolver.resolve().isMock)
        #expect(resolver.summaryModels(for: .openAI).contains { $0.id == "gpt-4o" })
    }

    private final class TranscriptionResolver: TranscriptionProviderResolving {
        var selections: [(TranscriptionProviderID?, String?)] = []
        func resolve() -> any TranscriptionProvider { MockTranscriptionProvider() }
        func resolve(provider: TranscriptionProviderID?, model: String?) -> any TranscriptionProvider {
            selections.append((provider, model))
            return MockTranscriptionProvider()
        }
    }

    @Test func transcriptionGenerationAndRegenerationUseSelection() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let recording = try await workspace.makeRecording(in: container.mainContext)
        let resolver = TranscriptionResolver()
        let model = RecordingViewModel(recording: recording, resolver: resolver, storage: workspace.storage)
        let repository = SwiftDataTranscriptRepository(context: container.mainContext)
        model.selectedProvider = .openAI
        model.selectedModel = "gpt-4o-mini-transcribe"
        await model.startTranscription(using: repository)?.value
        #expect(model.state == .completed)
        #expect(resolver.selections.last?.0 == .openAI)
        #expect(resolver.selections.last?.1 == "gpt-4o-mini-transcribe")
        model.selectedProvider = .localWhisper
        #expect(model.selectedModel == nil)
        model.selectedModel = "local-model"
        await model.startTranscription(using: repository, replacingExisting: true)?.value
        #expect(model.state == .completed)
        #expect(resolver.selections.last?.0 == .localWhisper)
        #expect(resolver.selections.last?.1 == "local-model")
        #expect(recording.transcriptHistory.count == 1)
    }

    @MainActor
    private final class SummaryResolver: LLMProviderResolving {
        var selections: [(LLMProviderID?, String?)] = []
        func resolve() -> any LLMProvider { MockLLMProvider() }
        func resolveSummary(provider: LLMProviderID?, model: String?) -> any LLMProvider {
            selections.append((provider, model))
            return MockLLMProvider()
        }
    }

    @Test func summaryGenerationAndRegenerationUseSelection() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let recording = try await workspace.makeRecording(in: container.mainContext)
        let transcript = Transcript()
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Discuss the project plan.")]
        recording.transcript = transcript
        let resolver = SummaryResolver()
        let model = SummaryViewModel(recording: recording, resolver: resolver)
        let repository = SwiftDataSummaryRepository(context: container.mainContext)
        model.selectedProvider = .openAI
        model.selectedModel = "gpt-4o"
        await model.generateSummary(using: repository)?.value
        #expect(model.state == .completed)
        #expect(resolver.selections.last?.0 == .openAI)
        #expect(resolver.selections.last?.1 == "gpt-4o")
        model.selectedProvider = .anthropic
        #expect(model.selectedModel == nil)
        model.selectedModel = "opus"
        await model.generateSummary(using: repository)?.value
        #expect(model.state == .completed)
        #expect(resolver.selections.last?.0 == .anthropic)
        #expect(resolver.selections.last?.1 == "opus")
        #expect(recording.summaryHistory.count == 1)
    }
}
