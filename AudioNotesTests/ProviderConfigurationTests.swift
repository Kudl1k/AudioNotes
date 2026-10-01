import Foundation
import Testing
@testable import AudioNotes

@MainActor
struct ProviderConfigurationTests {
    @Test func persistsOnlyNonSecretConfigurationAndFallsBackForUnknownValues() throws {
        let name = "AudioNotesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let config = TranscriptionConfiguration(defaults: defaults)
        #expect(config.selectedProvider == .mock)
        config.selectedProvider = .openAI
        config.openAIModel = .whisper1
        config.language = .czech
        let reopened = TranscriptionConfiguration(defaults: defaults)
        #expect(reopened.selectedProvider == .openAI)
        #expect(reopened.openAI == .init(model: .whisper1, language: .czech))
        let values = defaults.persistentDomain(forName: name) ?? [:]
        #expect(Set(values.keys) == Set(["transcription.provider", "transcription.openai.model", "transcription.language"]))
        defaults.set("unknown", forKey: "transcription.provider")
        defaults.set("unknown", forKey: "transcription.openai.model")
        defaults.set("unknown", forKey: "transcription.language")
        let fallback = TranscriptionConfiguration(defaults: defaults)
        #expect(fallback.selectedProvider == .mock)
        #expect(fallback.openAIModel == .whisper1)
        #expect(fallback.language == .automatic)
    }

    @Test func resolverUsesCurrentPreferencesAndKeepsMockAvailableWithoutKey() throws {
        let name = "AudioNotesTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let configuration = TranscriptionConfiguration(defaults: defaults)
        let resolver = TranscriptionProviderResolver(configuration: configuration, credentials: MockCredentialStore())
        #expect((resolver.resolve() as? PrivacyTranscriptionProvider)?.base is MockTranscriptionProvider)
        configuration.selectedProvider = .openAI
        configuration.language = .german
        let snapshot = try #require((resolver.resolve() as? PrivacyTranscriptionProvider)?.base as? OpenAITranscriptionProvider)
        #expect(snapshot.configuration.language == .german)
        configuration.language = .french
        #expect(snapshot.configuration.language == .german)
        #expect(((resolver.resolve() as? PrivacyTranscriptionProvider)?.base as? OpenAITranscriptionProvider)?.configuration.language == .french)
        configuration.selectedProvider = .mock
        #expect(resolver.resolve().isMock)
    }
}
