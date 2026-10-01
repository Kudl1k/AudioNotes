import Foundation

@MainActor
protocol TranscriptionProviderResolving {
    func resolve() -> any TranscriptionProvider
    func resolve(provider: TranscriptionProviderID?, model: String?) -> any TranscriptionProvider
    func models(for provider: TranscriptionProviderID) -> [GenerationModelOption]
}

extension TranscriptionProviderResolving {
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

    init(configuration: TranscriptionConfiguration, credentials: any CredentialStoring,
         client: OpenAITranscriptionClient = OpenAITranscriptionClient(),
         localConfiguration: LocalAIConfiguration? = nil, whisperStore: WhisperModelStore = WhisperModelStore()) {
        self.configuration = configuration
        self.credentials = credentials
        self.client = client
        self.localConfiguration = localConfiguration ?? LocalAIConfiguration()
        self.whisperStore = whisperStore
    }

    func resolve() -> any TranscriptionProvider {
        resolve(provider: nil, model: nil)
    }
    func resolve(provider: TranscriptionProviderID?, model: String?) -> any TranscriptionProvider {
        PrivacyTranscriptionProvider(base: resolveBase(provider: provider, model: model), configuration: localConfiguration)
    }

    func models(for provider: TranscriptionProviderID) -> [GenerationModelOption] {
        switch provider {
        case .mock: []
        case .openAI: configuration.availableVoiceModels.map { .init(id: $0.rawValue, title: $0.title) }
        case .localWhisper: WhisperModelDescriptor.bundled.map { .init(id: $0.id, title: $0.title) }
        }
    }

    private func resolveBase(provider: TranscriptionProviderID?, model: String?) -> any TranscriptionProvider {
        switch provider ?? configuration.selectedProvider {
        case .localWhisper:
            if let model = WhisperModelDescriptor.bundled.first(where: { $0.id == (model ?? localConfiguration.whisperModel) }) {
                return LocalWhisperTranscriptionProvider(model: model, language: localConfiguration.whisperLanguage.isEmpty ? nil : localConfiguration.whisperLanguage, store: whisperStore)
            } else { return MissingLocalWhisperProvider() }
        case .mock:
#if DEBUG
            return MockTranscriptionProvider()
#else
            return DisabledDevelopmentTranscriptionProvider()
#endif
        case .openAI:
            var settings = configuration.openAI
            if let model { settings.model = OpenAITranscriptionModel(rawValue: model) }
            return OpenAITranscriptionProvider(configuration: settings, credentials: credentials, client: client)
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
