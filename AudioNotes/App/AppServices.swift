import Foundation

/// App composition only; business logic belongs to feature view models and services.
@MainActor
final class AppServices {
    let configuration: TranscriptionConfiguration
    let llmConfiguration: LLMConfiguration
    let credentials = KeychainService()
    let chatGPTCredentials = ChatGPTCredentialStore()
    let localInference = LocalInferenceCoordinator()
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
#if DEBUG && os(iOS)
        if ProcessInfo.processInfo.arguments.contains("--performance-fixtures") {
            let reviewDefaults = UserDefaults(suiteName: "AudioNotes-iOS-UX-Review")!
            reviewDefaults.removePersistentDomain(forName: "AudioNotes-iOS-UX-Review")
            configuration = TranscriptionConfiguration(defaults: reviewDefaults)
            llmConfiguration = LLMConfiguration(defaults: reviewDefaults)
        } else {
            configuration = TranscriptionConfiguration()
            llmConfiguration = LLMConfiguration()
        }
#else
        configuration = TranscriptionConfiguration()
        llmConfiguration = LLMConfiguration()
#endif
        localAISettings = LocalAISettingsViewModel(configuration: llmConfiguration.localAI, store: whisperStore)
#if DEBUG && os(iOS)
        if ProcessInfo.processInfo.arguments.contains("--performance-fixtures"),
           let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--ios-local-ai-state"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
            localAISettings.prepareIOSReviewState(ProcessInfo.processInfo.arguments[index + 1])
        }
#endif
        let authService = ChatGPTAuthService(credentialStore: chatGPTCredentials)
        self.chatGPTAuthService = authService
        self.chatGPTTokenRefresher = ChatGPTTokenRefresher(credentialStore: chatGPTCredentials)
    }

    var transcriptionResolver: TranscriptionProviderResolver {
        TranscriptionProviderResolver(
            configuration: configuration,
            credentials: credentials,
            client: transcriptionClient,
            localConfiguration: llmConfiguration.localAI, whisperStore: whisperStore,
            geminiOAuth: googleGeminiOAuth, coordinator: localInference
        )
    }

    var llmResolver: LLMProviderResolver {
        LLMProviderResolver(
            configuration: llmConfiguration,
            credentials: credentials,
            client: llmClient,
            tokenRefresher: chatGPTTokenRefresher,
            responsesClient: chatGPTResponsesClient,
            geminiOAuth: googleGeminiOAuth, coordinator: localInference
        )
    }
}
