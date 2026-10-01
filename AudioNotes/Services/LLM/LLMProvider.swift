import Foundation

enum LLMProviderID: String, CaseIterable, Identifiable, Codable, Sendable {
    case mock
    case openAI
    case anthropic
    case gemini
    case ollama

    static var selectable: [Self] {
#if DEBUG
        allCases
#else
        allCases.filter { $0 != .mock }
#endif
    }
    static var defaultProvider: Self {
#if DEBUG
        .mock
#else
        .openAI
#endif
    }
    var id: Self { self }

    var title: String {
        switch self {
        case .mock: "Mock (development)"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        case .ollama: "Ollama"
        }
    }
}

enum LLMError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidAuthentication
    case accessDenied
    case rateLimited
    case creditBalanceExhausted
    case quotaExceeded
    case contextTooLarge(approximateTokens: Int)
    case transcriptEmpty
    case network(code: Int)
    case server(status: Int)
    case rejected(status: Int, message: String? = nil)
    case invalidResponse
    case refusal(message: String)
    case chatGPTNotSignedIn
    case chatGPTPlanNotEnabled
    case chatGPTUsageLimitExceeded(url: String)
    case chatGPTUsageUnavailable
    case chatGPTSessionExpired
    case providerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Add an OpenAI API key in Settings → AI Providers before generating a summary or chatting."
        case .invalidAuthentication:
            "OpenAI rejected the API key. Please verify or update it in Settings → AI Providers."
        case .accessDenied:
            "This OpenAI account does not have access to this model or project. Check your permissions."
        case .rateLimited:
            "OpenAI rate-limited this request. Please wait a moment before trying again."
        case .creditBalanceExhausted:
            "Your OpenAI API credit balance is exhausted. Please add credits at platform.openai.com."
        case .quotaExceeded:
            "Your OpenAI API quota is exhausted. Check your billing and project limits."
        case .contextTooLarge(let tokens):
            "The selected sources and conversation exceed this model's context budget (~\(tokens) tokens). Select fewer sources or shorten the conversation."
        case .transcriptEmpty:
            "The selected sources contain no readable context. Process a source or transcribe audio first."
        case .network(let code) where code == URLError.timedOut.rawValue:
            "The AI request timed out. Check your connection and try again."
        case .network:
            "Could not connect to the AI provider. Check your internet connection and try again."
        case .server(let status):
            "The AI provider is temporarily unavailable (status \(status)). Please try again later."
        case .rejected(let status, let message) where message != nil && !message!.isEmpty:
            "The provider rejected the request (\(status)): \(message!)"
        case .rejected(let status, _):
            "The request was rejected by the provider (\(status)). Please check your configuration."
        case .invalidResponse:
            "The provider returned an invalid structured response. Please try again."
        case .refusal(let message):
            "The model declined to answer: \(message)"
        case .chatGPTNotSignedIn:
            "Sign in with ChatGPT in Settings → AI Providers to use your ChatGPT plan."
        case .chatGPTPlanNotEnabled:
            "ChatGPT plan permissions were not granted. Please re-authorize in Settings → AI Providers or use an API key."
        case .chatGPTUsageLimitExceeded(let url):
            "ChatGPT plan usage limit reached. Check your usage at \(url) or switch to an API key."
        case .chatGPTUsageUnavailable:
            "ChatGPT plan usage is currently unavailable. Please try again later or switch to an API key."
        case .chatGPTSessionExpired:
            "Your ChatGPT session has expired. Please sign in again in Settings → AI Providers."
        case .providerUnavailable(let name):
            "\(name) is not configured in this build. Select another provider in Settings."
        }
    }
}

@MainActor
protocol LLMProvider: Sendable {
    var id: LLMProviderID { get }
    var displayName: String { get }
    var isMock: Bool { get }
    var authenticationMethod: ProviderAuthenticationMethod? { get }
    var modelID: String? { get }
    var supportsSourceSummaries: Bool { get }
    var inputCapabilities: LLMInputCapabilities { get }
    var executionLocation: ProviderExecutionLocation { get }
    var billingKind: BillingKind { get }
    func generateSourceSummary(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Summary

    func generateSummary(
        transcript: Transcript,
        configuration: SummaryConfiguration
    ) async throws -> Summary

    func streamChat(
        messages: [LLMChatMessage],
        context: ChatContext
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error>
}

extension LLMProvider {
    var isMock: Bool { id == .mock }
    var executionLocation: ProviderExecutionLocation { id == .mock ? .local : .cloud }
    var billingKind: BillingKind { BillingKind.resolve(provider: id.rawValue, authentication: authenticationMethod) }
    var authenticationMethod: ProviderAuthenticationMethod? { nil }
    var modelID: String? { nil }
    var supportsSourceSummaries: Bool { false }
    var inputCapabilities: LLMInputCapabilities { .known(model: modelID, provider: id) }

    func generateSourceSummary(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Summary {
        throw LLMError.providerUnavailable("Multi-source summaries for this provider")
    }

    func chat(
        messages: [LLMChatMessage],
        context: ChatContext
    ) async throws -> LLMChatResponse {
        var accumulatedText = ""
        var references: [TranscriptReference] = []
        let stream = try await streamChat(messages: messages, context: context)
        for try await event in stream {
            switch event {
            case .usage: break
            case .textDelta(let delta):
                accumulatedText.append(delta)
            case .references(let refs):
                references = refs
            case .completed(let response):
                return response
            }
        }
        return LLMChatResponse(content: accumulatedText, references: references)
    }
}
