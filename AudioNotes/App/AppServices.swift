import Foundation

/// App composition only; business logic belongs to feature view models and services.
@MainActor
final class AppServices {
    let configuration: TranscriptionConfiguration
    let llmConfiguration: LLMConfiguration
    let credentials = KeychainService()
    let chatGPTCredentials = ChatGPTCredentialStore()
    let whisperStore = WhisperModelStore()
    let localAISettings: LocalAISettingsViewModel
    let transcriptionClient = OpenAITranscriptionClient()
    let llmClient = OpenAILLMClient()
    let chatGPTAuthService: ChatGPTAuthService
    let chatGPTTokenRefresher: ChatGPTTokenRefresher
    let chatGPTResponsesClient = ChatGPTResponsesClient()
    let modelsClient = OpenAIModelsClient()
    let googleGeminiOAuth = GoogleGeminiOAuthService()

    init() {
        AppStorageLocations.restorePreferences()
        configuration = TranscriptionConfiguration()
        llmConfiguration = LLMConfiguration()
        localAISettings = LocalAISettingsViewModel(configuration: llmConfiguration.localAI, store: whisperStore)
        let authService = ChatGPTAuthService(credentialStore: chatGPTCredentials)
        self.chatGPTAuthService = authService
        self.chatGPTTokenRefresher = ChatGPTTokenRefresher(credentialStore: chatGPTCredentials)
    }

    var transcriptionResolver: TranscriptionProviderResolver {
        TranscriptionProviderResolver(
            configuration: configuration,
            credentials: credentials,
            client: transcriptionClient,
            localConfiguration: llmConfiguration.localAI, whisperStore: whisperStore
        )
    }

    var llmResolver: LLMProviderResolver {
        LLMProviderResolver(
            configuration: llmConfiguration,
            credentials: credentials,
            client: llmClient,
            tokenRefresher: chatGPTTokenRefresher,
            responsesClient: chatGPTResponsesClient
        )
    }
}
