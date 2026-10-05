import Foundation

@MainActor
protocol TranscriptionProviderResolving {
    func resolve() -> any TranscriptionProvider
    func resolve(provider: TranscriptionProviderID?, model: String?) -> any TranscriptionProvider
    func models(for provider: TranscriptionProviderID) -> [GenerationModelOption]
    func resolve(provider: TranscriptionProviderID?, model: String?, language: TranscriptionLanguage?) -> any TranscriptionProvider
}

extension TranscriptionProviderResolving {
    func resolve(provider: TranscriptionProviderID?, model: String?, language: TranscriptionLanguage?) -> any TranscriptionProvider {
        resolve(provider: provider, model: model)
    }
    func resolve(provider: TranscriptionProviderID?, model: String?) -> any TranscriptionProvider { resolve() }
    func models(for provider: TranscriptionProviderID) -> [GenerationModelOption] { [] }
}

@MainActor
struct TranscriptionProviderResolver: TranscriptionProviderResolving {
    let configuration: TranscriptionConfiguration
    let credentials: any CredentialStoring
    let client: OpenAITranscriptionClient
    let localConfiguration: LocalAIConfiguration
    let whisperStore: WhisperModelStore
    let coordinator: LocalInferenceCoordinator?
    let geminiOAuth: GoogleGeminiOAuthService

    init(configuration: TranscriptionConfiguration, credentials: any CredentialStoring,
         client: OpenAITranscriptionClient = OpenAITranscriptionClient(),
         localConfiguration: LocalAIConfiguration? = nil, whisperStore: WhisperModelStore = WhisperModelStore(),
         geminiOAuth: GoogleGeminiOAuthService = GoogleGeminiOAuthService(), coordinator: LocalInferenceCoordinator? = nil) {
        self.configuration = configuration
        self.credentials = credentials
        self.client = client
        self.localConfiguration = localConfiguration ?? LocalAIConfiguration()
        self.whisperStore = whisperStore
        self.coordinator = coordinator
        self.geminiOAuth = geminiOAuth
    }

    func resolve() -> any TranscriptionProvider {
        resolve(provider: nil, model: nil)
    }
    func resolve(provider: TranscriptionProviderID?, model: String?) -> any TranscriptionProvider {
        resolve(provider: provider, model: model, language: nil)
    }
    func resolve(provider: TranscriptionProviderID?, model: String?, language: TranscriptionLanguage?) -> any TranscriptionProvider {
        PrivacyTranscriptionProvider(base: resolveBase(provider: provider, model: model, language: language), configuration: localConfiguration)
    }

    func models(for provider: TranscriptionProviderID) -> [GenerationModelOption] {
        switch provider {
        case .mock: []
        case .openAI: configuration.availableVoiceModels.map { .init(id: $0.rawValue, title: $0.title) }
        case .gemini: [.init(id: "gemini-3.5-transcribe", title: "Gemini 3.5 Transcribe (timestamps and speakers)")]
        case .localWhisper: WhisperModelDescriptor.selectable.map { .init(id: $0.id, title: $0.title) }
        }
    }

    private func resolveBase(provider: TranscriptionProviderID?, model: String?, language: TranscriptionLanguage?) -> any TranscriptionProvider {
        switch provider ?? configuration.selectedProvider {
        case .localWhisper:
            if let model = WhisperModelDescriptor.selectable.first(where: { $0.id == (model ?? localConfiguration.whisperModel) }) {
                return LocalWhisperTranscriptionProvider(model: model, language: language == nil ? (localConfiguration.whisperLanguage.isEmpty ? nil : localConfiguration.whisperLanguage) : language?.code, store: whisperStore, coordinator: coordinator)
            } else { return MissingLocalWhisperProvider() }
        case .mock:
#if DEBUG
            return MockTranscriptionProvider()
#else
            return DisabledDevelopmentTranscriptionProvider()
#endif
        case .openAI:
            var settings = configuration.openAI
            if let language { settings.language = language }
            if let model { settings.model = OpenAITranscriptionModel(rawValue: model) }
            return OpenAITranscriptionProvider(configuration: settings, credentials: credentials, client: client)
        case .gemini:
            return GeminiTranscriptionProvider(model: model ?? configuration.geminiModel, oauth: geminiOAuth)
        }
    }
}

/// Preserves direct provider injection for previews and Milestone 2 tests.
@MainActor
struct FixedTranscriptionProviderResolver: TranscriptionProviderResolving {
    let provider: any TranscriptionProvider
    func resolve() -> any TranscriptionProvider { provider }
}

@MainActor private struct MissingLocalWhisperProvider: TranscriptionProvider {
    let displayName = "Local Whisper"
    var executionLocation: ProviderExecutionLocation { .local }
    var providerID: String? { "localWhisper" }
    var billingKind: BillingKind { .local }
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        throw LocalAIError.missingModel("Selected Whisper model")
    }
}

@MainActor private struct DisabledDevelopmentTranscriptionProvider: TranscriptionProvider {
    let displayName = "Unavailable development provider"
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        throw TranscriptionError.invalidTranscript
    }
}
