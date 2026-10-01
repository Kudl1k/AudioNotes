import Foundation
import Security
import Testing
@testable import AudioNotes

private struct MockOpenAIModelsClient: OpenAIModelsFetching {
    var models: [OpenAIModelItem] = []
    var error: Error?

    func fetchModels(bearerToken: String) async throws -> [OpenAIModelItem] {
        if let error {
            throw error
        }
        return models
    }
}

private struct MockChatGPTTokenRefresher: ChatGPTTokenRefreshing {
    var token: String = "test_token"
    func validAccessToken(clockTolerance: TimeInterval) async throws -> String {
        token
    }
}

@MainActor
struct ProviderSettingsTests {
    @Test func providerKeysAreSavedAndRestoredIndependently() async throws {
        let store = MockCredentialStore()
        let settings = ProviderSettingsViewModel(credentials: store)
        await settings.refresh()
        settings.anthropicKeyInput = "anthropic-placeholder"
        settings.geminiKeyInput = "gemini-placeholder"
        await settings.saveProviderKey(.anthropic)
        await settings.saveProviderKey(.gemini)

        let reopened = ProviderSettingsViewModel(credentials: store)
        await reopened.refresh()
        #expect(reopened.anthropicKeyIsConfigured)
        #expect(reopened.geminiKeyIsConfigured)
        #expect(reopened.anthropicKeyInput.isEmpty)
        #expect(reopened.geminiKeyInput.isEmpty)
        #expect(try await store.apiKey(for: .anthropic) == "anthropic-placeholder")
        #expect(try await store.apiKey(for: .gemini) == "gemini-placeholder")

        await reopened.removeProviderKey(.anthropic)
        #expect(!reopened.anthropicKeyIsConfigured)
        #expect(reopened.geminiKeyIsConfigured)
    }

    @Test func credentialLifecycleNeverLoadsStoredSecretIntoSettings() async throws {
        let store = MockCredentialStore()
        let model = ProviderSettingsViewModel(credentials: store)
        await model.refresh()
        #expect(!model.keyIsConfigured)
        model.keyInput = "placeholder-for-offline-test"
        await model.saveKey()
        #expect(model.keyInput.isEmpty)
        #expect(model.keyIsConfigured)
        #expect(model.status == "API key configured")
        model.keyInput = "replacement-placeholder"
        await model.saveKey()
        #expect(try await store.apiKey(for: .openAI) == "replacement-placeholder")
        let reopened = ProviderSettingsViewModel(credentials: store)
        await reopened.refresh()
        #expect(reopened.keyIsConfigured)
        #expect(reopened.keyInput.isEmpty)
        #expect(await store.secretReads == 1) // Only the explicit test retrieval above.
        await reopened.removeKey()
        #expect(!reopened.keyIsConfigured)
        #expect(try await store.apiKey(for: .openAI) == nil)
        await reopened.removeKey()
        #expect(reopened.errorMessage == nil)
    }

    @Test func keychainFailureDoesNotClaimKeyWasSaved() async {
        let model = ProviderSettingsViewModel(credentials: MockCredentialStore(failure: .locked))
        model.keyInput = "placeholder-for-offline-test"
        await model.saveKey()
        #expect(!model.keyIsConfigured)
        #expect(model.errorMessage == KeychainError.locked.localizedDescription)
        #expect(!model.isBusy)
    }

    @Test func invalidInputAndStatusMapping() throws {
        #expect(throws: KeychainError.invalidKey) { try APIKeyInput.normalized("  ") }
        #expect(throws: KeychainError.invalidKey) { try APIKeyInput.normalized("value\r\ninjected") }
        #expect(try APIKeyInput.normalized("  placeholder\n") == "placeholder")
        #expect(KeychainError(status: errSecAuthFailed) == .accessDenied)
        #expect(KeychainError(status: errSecInteractionNotAllowed) == .locked)
        #expect(KeychainError(status: errSecNotAvailable) == .unavailable)
        #expect(KeychainError(status: -1234) == .unexpectedStatus(-1234))
    }

    @Test func fetchVoiceModelsFiltersVoiceAndUpdatesConfiguration() async throws {
        let store = MockCredentialStore()
        try await store.saveAPIKey("sk-valid-key", for: .openAI)

        let mockModels = [
            OpenAIModelItem(slug: "whisper-1", displayName: "Whisper 1"),
            OpenAIModelItem(slug: "gpt-4o-transcribe", displayName: "GPT-4o Transcribe"),
            OpenAIModelItem(slug: "gpt-4o-text", displayName: "GPT-4o Text"),
            OpenAIModelItem(slug: "dall-e-3", displayName: "DALL-E 3")
        ]

        let suiteName = "ProviderSettingsVoiceTests_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let transcriptionConfig = TranscriptionConfiguration(defaults: defaults)

        let model = ProviderSettingsViewModel(
            credentials: store,
            modelsClient: MockOpenAIModelsClient(models: mockModels),
            transcriptionConfig: transcriptionConfig
        )

        await model.refresh()
        // Ensure refresh does not read secret or fetch models
        #expect(await store.secretReads == 0)

        await model.fetchVoiceModels()
        #expect(await store.secretReads == 1)

        let slugs = model.availableTranscriptionModels.map(\.rawValue)
        #expect(slugs.contains("whisper-1"))
        #expect(slugs.contains("gpt-4o-transcribe"))
        #expect(!slugs.contains("gpt-4o-text"))
        #expect(!slugs.contains("dall-e-3"))

        #expect(transcriptionConfig.availableVoiceModels.map(\.rawValue).contains("gpt-4o-transcribe"))
    }

    @Test func fetchChatGPTModelsFiltersMiniAndUpdatesConfiguration() async throws {
        let store = MockCredentialStore()
        let mockAuth = MockChatGPTAuthService()
        mockAuth.authState = .signedIn(account: ChatGPTAccount(
            id: "user_test",
            email: "test@openai.com",
            displayName: "Tester",
            issuedClientID: "oaiapp_xyz",
            grantedScopes: ["chatgpt.tokens.use.direct"],
            planUsageEnabled: true,
            expiresAt: Date().addingTimeInterval(3600)
        ))

        let mockModels = [
            OpenAIModelItem(slug: "gpt-4o", displayName: "GPT-4o", visibility: "list"),
            OpenAIModelItem(slug: "gpt-4o-mini", displayName: "GPT-4o Mini", visibility: "list"),
            OpenAIModelItem(slug: "o3-mini", displayName: "o3-mini", visibility: "list"),
            OpenAIModelItem(slug: "internal-model", displayName: "Internal", visibility: "hidden")
        ]

        let suiteName = "ProviderSettingsChatGPTModelsTests_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let llmConfig = LLMConfiguration(defaults: defaults)
        llmConfig.chatGPTModel = "gpt-4o-mini" // Initially set to invalid model

        let model = ProviderSettingsViewModel(
            credentials: store,
            chatGPTAuth: mockAuth,
            tokenRefresher: MockChatGPTTokenRefresher(),
            modelsClient: MockOpenAIModelsClient(models: mockModels),
            llmConfig: llmConfig
        )

        #expect(model.isChatGPTSignedIn)

        await model.fetchChatGPTModels()

        let slugs = model.availableChatGPTModels.map(\.slug)
        #expect(slugs.contains("gpt-4o"))
        #expect(slugs.contains("o3-mini"))
        #expect(!slugs.contains("gpt-4o-mini")) // Filtered out
        #expect(!slugs.contains("internal-model")) // Hidden filtered out

        // Model selection should have adjusted away from gpt-4o-mini
        #expect(llmConfig.chatGPTModel != "gpt-4o-mini")
        #expect(llmConfig.cachedChatGPTModels.map(\.slug).contains("gpt-4o"))
    }
}
