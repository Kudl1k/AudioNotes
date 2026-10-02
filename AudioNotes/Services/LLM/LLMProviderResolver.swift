import Foundation

protocol LLMProviderResolving: Sendable {
    @MainActor func resolve() -> any LLMProvider
    @MainActor func resolveChat() -> any LLMProvider
    @MainActor func resolveSummary(provider: LLMProviderID?, model: String?) -> any LLMProvider
    @MainActor func summaryModels(for provider: LLMProviderID) -> [GenerationModelOption]
    @MainActor func summarySettings() -> LLMGenerationSettings
    @MainActor func chatSettings() -> LLMGenerationSettings
}

extension LLMProviderResolving {
    @MainActor func summaryModels(for provider: LLMProviderID) -> [GenerationModelOption] { [] }
    @MainActor func resolveSummary(provider: LLMProviderID?, model: String?) -> any LLMProvider { resolve() }
    @MainActor func resolveChat() -> any LLMProvider {
        resolve()
    }
    @MainActor func summarySettings() -> LLMGenerationSettings { LLMGenerationSettings() }
    @MainActor func chatSettings() -> LLMGenerationSettings { LLMGenerationSettings() }
}

final class LLMProviderResolver: LLMProviderResolving, Sendable {
    private let configuration: LLMConfiguration
    private let credentials: any CredentialStoring
    private let client: OpenAILLMClient
    private let tokenRefresher: any ChatGPTTokenRefreshing
    private let responsesClient: ChatGPTResponsesClient

    init(
        configuration: LLMConfiguration,
        credentials: any CredentialStoring,
        client: OpenAILLMClient = OpenAILLMClient(),
        tokenRefresher: any ChatGPTTokenRefreshing = ChatGPTTokenRefresher(),
        responsesClient: ChatGPTResponsesClient = ChatGPTResponsesClient()
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.client = client
        self.tokenRefresher = tokenRefresher
        self.responsesClient = responsesClient
    }

    @MainActor
    func resolve() -> any LLMProvider {
        PrivacyLLMProvider(base: resolveSummaryBase(), configuration: configuration.localAI)
    }

    @MainActor func resolveSummary(provider: LLMProviderID?, model: String?) -> any LLMProvider {
        PrivacyLLMProvider(base: resolveSummaryBase(provider: provider, model: model), configuration: configuration.localAI)
    }

    @MainActor func summaryModels(for provider: LLMProviderID) -> [GenerationModelOption] {
        switch provider {
        case .openAI:
            if configuration.summaryAuthMethod == .chatGPT {
                return configuration.cachedChatGPTModels.map { .init(id: $0.slug, title: $0.displayName) }
            }
            return OpenAILLMModel.allCases.map { .init(id: $0.rawValue, title: $0.title) }
        case .anthropic:
#if os(macOS)
            guard PlatformCapabilities.current.supportsClaudeCLI else { return [] }
            return configuration.cachedClaudeModels.map { .init(id: $0.id, title: $0.displayName) }
#else
            return []
#endif
        case .ollama:
            return configuration.localAI.models.map { .init(id: $0.id, title: $0.id) }
        case .llamaCpp:
            let model = configuration.localAI.llamaCppModel
            return model.isEmpty ? [] : [.init(id: model, title: model)]
        case .mock, .gemini: return []
        }
    }

    @MainActor private func resolveSummaryBase(provider: LLMProviderID? = nil, model: String? = nil) -> any LLMProvider {
        let selectedProvider = provider ?? configuration.summaryProvider
        switch selectedProvider {
        case .ollama:
            return OllamaLLMProvider(model: model ?? configuration.localAI.summaryModel, configuration: configuration.localAI)
        case .llamaCpp:
            return LlamaCppLLMProvider(model: model ?? configuration.localAI.llamaCppModel, configuration: configuration.localAI)
        case .mock:
#if DEBUG
            return MockLLMProvider()
#else
            return UnavailableLLMProvider(providerID: .mock)
#endif
        case .anthropic:
#if os(macOS)
            if PlatformCapabilities.current.supportsClaudeCLI {
                return ClaudeCLILLMProvider(model: model ?? configuration.summaryClaudeModel,
                                            client: ClaudeCLIClient(executable: configuration.claudeExecutablePath))
            } else {
                return UnavailableLLMProvider(providerID: selectedProvider)
            }
#else
            return UnavailableLLMProvider(providerID: selectedProvider)
#endif
        case .gemini:
            return UnavailableLLMProvider(providerID: selectedProvider)
        case .openAI:
            switch configuration.summaryAuthMethod {
            case .chatGPT:
                let model = model ?? (configuration.summaryChatGPTModel.isEmpty ? "gpt-4o" : configuration.summaryChatGPTModel)
                return ChatGPTPlanLLMProvider(
                    defaultModel: model,
                    tokenRefresher: tokenRefresher,
                    responsesClient: responsesClient
                )
            case .apiKey:
                return OpenAILLMProvider(
                    defaultModel: model ?? configuration.summaryOpenAIModel.rawValue,
                    credentials: credentials,
                    client: client
                )
            }
        }
    }

    @MainActor
    func resolveChat() -> any LLMProvider {
        PrivacyLLMProvider(base: resolveChatBase(), configuration: configuration.localAI)
    }

    @MainActor private func resolveChatBase() -> any LLMProvider {
        switch configuration.chatProvider {
        case .ollama:
            return OllamaLLMProvider(model: configuration.localAI.chatModel, configuration: configuration.localAI)
        case .llamaCpp:
            return LlamaCppLLMProvider(model: configuration.localAI.llamaCppModel, configuration: configuration.localAI)
        case .mock:
#if DEBUG
            return MockLLMProvider()
#else
            return UnavailableLLMProvider(providerID: .mock)
#endif
        case .anthropic:
#if os(macOS)
            if PlatformCapabilities.current.supportsClaudeCLI {
                return ClaudeCLILLMProvider(model: configuration.chatClaudeModel,
                                            client: ClaudeCLIClient(executable: configuration.claudeExecutablePath))
            } else {
                return UnavailableLLMProvider(providerID: configuration.chatProvider)
            }
#else
            return UnavailableLLMProvider(providerID: configuration.chatProvider)
#endif
        case .gemini:
            return UnavailableLLMProvider(providerID: configuration.chatProvider)
        case .openAI:
            switch configuration.chatAuthMethod {
            case .chatGPT:
                let model = configuration.chatChatGPTModel.isEmpty ? "gpt-4o" : configuration.chatChatGPTModel
                return ChatGPTPlanLLMProvider(
                    defaultModel: model,
                    tokenRefresher: tokenRefresher,
                    responsesClient: responsesClient
                )
            case .apiKey:
                return OpenAILLMProvider(
                    defaultModel: configuration.chatOpenAIModel.rawValue,
                    credentials: credentials,
                    client: client
                )
            }
        }
    }

    @MainActor func summarySettings() -> LLMGenerationSettings {
        var settings = configuration.summarySettings
        settings.outputLength = configuration.summaryOutputLength
        return settings.sanitized(for: configuration.summaryCapabilities)
    }

    @MainActor func chatSettings() -> LLMGenerationSettings {
        var settings = configuration.chatSettings
        settings.outputLength = configuration.chatOutputLength
        return settings.sanitized(for: configuration.chatCapabilities)
    }
}

@MainActor
internal final class UnavailableLLMProvider: LLMProvider {
    let id: LLMProviderID
    var displayName: String { id.title }
    init(providerID: LLMProviderID) { id = providerID }
    func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
        throw LLMError.providerUnavailable(displayName)
    }
    func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        throw LLMError.providerUnavailable(displayName)
    }
}

/// Preserves direct provider injection for previews and tests.
@MainActor
struct FixedLLMProviderResolver: LLMProviderResolving {
    let provider: any LLMProvider
    func resolve() -> any LLMProvider { provider }
    func resolveChat() -> any LLMProvider { provider }
}
