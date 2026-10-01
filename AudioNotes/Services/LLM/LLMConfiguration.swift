import Foundation
import Observation

enum OpenAILLMModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case gpt4oMini = "gpt-4o-mini"
    case gpt4o = "gpt-4o"

    var id: Self { self }

    var title: String {
        switch self {
        case .gpt4oMini: "GPT-4o mini (fast, recommended)"
        case .gpt4o: "GPT-4o (flagship, detailed)"
        }
    }
}

enum OpenAIAuthenticationMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case chatGPT = "chatgpt"
    case apiKey = "api_key"

    var id: Self { self }

    var title: String {
        switch self {
        case .chatGPT: "ChatGPT Plan (Sign in with ChatGPT)"
        case .apiKey: "OpenAI API Key"
        }
    }
}

/// Contains only non-secret preferences. Invalid/stale values fall back safely.
@MainActor
@Observable
final class LLMConfiguration {
    @ObservationIgnored private let defaults: UserDefaults
    let localAI: LocalAIConfiguration

    var summaryGeminiAuthenticationMethod: ProviderAuthenticationMethod {
        didSet { defaults.set(summaryGeminiAuthenticationMethod.rawValue, forKey: "llm.summary.gemini.auth_method") }
    }
    var chatGeminiAuthenticationMethod: ProviderAuthenticationMethod {
        didSet { defaults.set(chatGeminiAuthenticationMethod.rawValue, forKey: "llm.chat.gemini.auth_method") }
    }

    var claudeExecutablePath: String {
        didSet {
            defaults.set(claudeExecutablePath, forKey: "llm.claude.executable")
            if claudeExecutablePath != oldValue { cachedClaudeModels = [] }
        }
    }
    var cachedClaudeModels: [ClaudeCLIModel] {
        didSet {
            defaults.set(try? JSONEncoder().encode(cachedClaudeModels), forKey: "llm.claude.cached_models")
            defaults.set(claudeExecutablePath, forKey: "llm.claude.cached_models_executable")
        }
    }
    var summaryClaudeModel: String {
        didSet { defaults.set(summaryClaudeModel, forKey: "llm.summary.claude.model") }
    }
    var chatClaudeModel: String {
        didSet { defaults.set(chatClaudeModel, forKey: "llm.chat.claude.model") }
    }

    // MARK: - Summary Configuration
    var summaryProvider: LLMProviderID {
        didSet {
            defaults.set(summaryProvider.rawValue, forKey: "llm.summary.provider")
            defaults.set(summaryProvider.rawValue, forKey: "llm.provider")
        }
    }
    var summaryAuthMethod: OpenAIAuthenticationMethod {
        didSet {
            defaults.set(summaryAuthMethod.rawValue, forKey: "llm.summary.auth_method")
            defaults.set(summaryAuthMethod.rawValue, forKey: "llm.openai.auth_method")
        }
    }
    var summaryOpenAIModel: OpenAILLMModel {
        didSet {
            defaults.set(summaryOpenAIModel.rawValue, forKey: "llm.summary.openai.model")
            defaults.set(summaryOpenAIModel.rawValue, forKey: "llm.openai.model")
        }
    }
    var summaryChatGPTModel: String {
        didSet {
            defaults.set(summaryChatGPTModel, forKey: "llm.summary.chatgpt.model")
            defaults.set(summaryChatGPTModel, forKey: "llm.chatgpt.model")
        }
    }
    var summarySettings: LLMGenerationSettings {
        didSet { saveSettings(summarySettings, prefix: "llm.summary.settings") }
    }
    var defaultPreset: SummaryPreset {
        didSet { defaults.set(defaultPreset.rawValue, forKey: "llm.summary.preset") }
    }
    var summaryOutputLength: OutputLength {
        didSet {
            defaults.set(summaryOutputLength.rawValue, forKey: "llm.summary.output_length")
            summarySettings.outputLength = summaryOutputLength
        }
    }

    // MARK: - Chat Configuration
    var chatProvider: LLMProviderID {
        didSet { defaults.set(chatProvider.rawValue, forKey: "llm.chat.provider") }
    }
    var chatAuthMethod: OpenAIAuthenticationMethod {
        didSet { defaults.set(chatAuthMethod.rawValue, forKey: "llm.chat.auth_method") }
    }
    var chatOpenAIModel: OpenAILLMModel {
        didSet { defaults.set(chatOpenAIModel.rawValue, forKey: "llm.chat.openai.model") }
    }
    var chatChatGPTModel: String {
        didSet { defaults.set(chatChatGPTModel, forKey: "llm.chat.chatgpt.model") }
    }
    var chatSettings: LLMGenerationSettings {
        didSet { saveSettings(chatSettings, prefix: "llm.chat.settings") }
    }
    var chatOutputLength: OutputLength {
        didSet {
            defaults.set(chatOutputLength.rawValue, forKey: "llm.chat.output_length")
            chatSettings.outputLength = chatOutputLength
        }
    }

    // MARK: - Backwards Compatibility Aliases
    var selectedProvider: LLMProviderID {
        get { summaryProvider }
        set {
            summaryProvider = newValue
            if defaults.string(forKey: "llm.chat.provider") == nil {
                chatProvider = newValue
            }
        }
    }
    var openAIModel: OpenAILLMModel {
        get { summaryOpenAIModel }
        set { summaryOpenAIModel = newValue }
    }
    var openAIAuthMethod: OpenAIAuthenticationMethod {
        get { summaryAuthMethod }
        set {
            summaryAuthMethod = newValue
            if defaults.string(forKey: "llm.chat.auth_method") == nil {
                chatAuthMethod = newValue
            }
        }
    }
    var chatGPTModel: String {
        get { summaryChatGPTModel }
        set { summaryChatGPTModel = newValue }
    }

    // MARK: - Cached Models
    var cachedChatGPTModels: [OpenAIModelItem] {
        get {
            guard let data = defaults.data(forKey: "llm.chatgpt.cached_models"),
                  let decoded = try? JSONDecoder().decode([OpenAIModelItem].self, from: data),
                  !decoded.isEmpty else {
                return [
                    OpenAIModelItem(slug: "gpt-4o", displayName: "GPT-4o (flagship)"),
                    OpenAIModelItem(slug: "o3-mini", displayName: "o3-mini (reasoning)")
                ]
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "llm.chatgpt.cached_models")
            }
        }
    }

    // MARK: - Capabilities Resolution
    var summaryCapabilities: LLMModelCapabilities {
        if summaryProvider == .anthropic { return Self.claudeCapabilities }
        if summaryProvider == .ollama { return localAI.capabilities(model: localAI.summaryModel) }
        let model = summaryProvider == .openAI
            ? (summaryAuthMethod == .chatGPT ? summaryChatGPTModel : summaryOpenAIModel.rawValue)
            : LLMProviderID.defaultProvider.rawValue
        var capabilities = LLMModelCapabilities.capabilities(for: model, provider: summaryProvider)
        // The ChatGPT-plan Responses endpoint currently rejects max_output_tokens.
        // Keep the saved value intact so switching back to API-key auth restores it.
        if summaryProvider == .openAI && summaryAuthMethod == .chatGPT {
            capabilities.supportsMaxOutputTokens = false
        }
        return capabilities
    }

    var chatCapabilities: LLMModelCapabilities {
        if chatProvider == .anthropic { return Self.claudeCapabilities }
        if chatProvider == .ollama { return localAI.capabilities(model: localAI.chatModel) }
        let model = chatProvider == .openAI
            ? (chatAuthMethod == .chatGPT ? chatChatGPTModel : chatOpenAIModel.rawValue)
            : LLMProviderID.defaultProvider.rawValue
        var capabilities = LLMModelCapabilities.capabilities(for: model, provider: chatProvider)
        if chatProvider == .openAI && chatAuthMethod == .chatGPT {
            capabilities.supportsMaxOutputTokens = false
        }
        return capabilities
    }

    static var claudeCapabilities: LLMModelCapabilities {
        LLMModelCapabilities.capabilities(for: "sonnet", provider: .anthropic)
    }

    // MARK: - Initializer
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedClaudeExecutablePath = defaults.string(forKey: "llm.claude.executable") ?? ""
        claudeExecutablePath = savedClaudeExecutablePath
        if defaults.string(forKey: "llm.claude.cached_models_executable") == savedClaudeExecutablePath,
           let data = defaults.data(forKey: "llm.claude.cached_models") {
            cachedClaudeModels = (try? JSONDecoder().decode([ClaudeCLIModel].self, from: data)) ?? []
        } else { cachedClaudeModels = [] }
        summaryClaudeModel = defaults.string(forKey: "llm.summary.claude.model") ?? "sonnet"
        chatClaudeModel = defaults.string(forKey: "llm.chat.claude.model") ?? "sonnet"
        localAI = LocalAIConfiguration(defaults: defaults)
        summaryGeminiAuthenticationMethod = ProviderAuthenticationMethod(rawValue: defaults.string(forKey: "llm.summary.gemini.auth_method") ?? "") ?? .apiKey
        chatGeminiAuthenticationMethod = ProviderAuthenticationMethod(rawValue: defaults.string(forKey: "llm.chat.gemini.auth_method") ?? "") ?? .apiKey

        // Summary Provider
        let sumProviderRaw = defaults.string(forKey: "llm.summary.provider") ?? defaults.string(forKey: "llm.provider") ?? ""
        let resolvedSummaryProvider = LLMProviderID(rawValue: sumProviderRaw) ?? .defaultProvider
        summaryProvider = resolvedSummaryProvider

        // Summary Auth Method
        let sumAuthRaw = defaults.string(forKey: "llm.summary.auth_method") ?? defaults.string(forKey: "llm.openai.auth_method") ?? ""
        let resolvedSummaryAuth = OpenAIAuthenticationMethod(rawValue: sumAuthRaw) ?? .chatGPT
        summaryAuthMethod = resolvedSummaryAuth

        // Summary Models
        let sumOpenAIModelRaw = defaults.string(forKey: "llm.summary.openai.model") ?? defaults.string(forKey: "llm.openai.model") ?? ""
        summaryOpenAIModel = OpenAILLMModel(rawValue: sumOpenAIModelRaw) ?? .gpt4oMini

        let sumChatGPTModelRaw = defaults.string(forKey: "llm.summary.chatgpt.model") ?? defaults.string(forKey: "llm.chatgpt.model")
        if let sumChatGPTModelRaw, !sumChatGPTModelRaw.isEmpty, sumChatGPTModelRaw != "gpt-4o-mini" {
            summaryChatGPTModel = sumChatGPTModelRaw
        } else {
            summaryChatGPTModel = "gpt-4o"
        }

        defaultPreset = SummaryPreset(rawValue: defaults.string(forKey: "llm.summary.preset") ?? "") ?? .general
        summarySettings = Self.loadSettings(defaults: defaults, prefix: "llm.summary.settings")

        // Chat Provider
        // Chat has independent defaults. Do not inherit an unavailable summary
        // provider (for example Claude) and leave chat unable to send.
        let chatProvRaw = defaults.string(forKey: "llm.chat.provider") ?? ""
        chatProvider = LLMProviderID(rawValue: chatProvRaw) ?? .openAI

        // Chat Auth Method
        let chatAuthRaw = defaults.string(forKey: "llm.chat.auth_method") ?? defaults.string(forKey: "llm.openai.auth_method") ?? ""
        chatAuthMethod = OpenAIAuthenticationMethod(rawValue: chatAuthRaw) ?? resolvedSummaryAuth

        // Chat Models
        let chatOpenAIModelRaw = defaults.string(forKey: "llm.chat.openai.model") ?? ""
        chatOpenAIModel = OpenAILLMModel(rawValue: chatOpenAIModelRaw) ?? .gpt4oMini

        let storedChatChatGPTModel = defaults.string(forKey: "llm.chat.chatgpt.model")
        if let storedChatChatGPTModel, !storedChatChatGPTModel.isEmpty, storedChatChatGPTModel != "gpt-4o-mini" {
            chatChatGPTModel = storedChatChatGPTModel
        } else {
            chatChatGPTModel = "gpt-4o"
        }

        chatSettings = Self.loadSettings(defaults: defaults, prefix: "llm.chat.settings")
        summaryOutputLength = OutputLength(rawValue: defaults.string(forKey: "llm.summary.output_length") ?? "") ?? .medium
        chatOutputLength = OutputLength(rawValue: defaults.string(forKey: "llm.chat.output_length") ?? "") ?? .medium
    }

    private func saveSettings(_ settings: LLMGenerationSettings, prefix: String) {
        defaults.set(settings.outputLength.rawValue, forKey: "\(prefix).output_length")
        if let maxTokens = settings.maxOutputTokens {
            defaults.set(maxTokens, forKey: "\(prefix).max_tokens")
        } else {
            defaults.removeObject(forKey: "\(prefix).max_tokens")
        }

        if let temp = settings.temperature {
            defaults.set(temp, forKey: "\(prefix).temperature")
        } else {
            defaults.removeObject(forKey: "\(prefix).temperature")
        }

        if let topP = settings.topP {
            defaults.set(topP, forKey: "\(prefix).top_p")
        } else {
            defaults.removeObject(forKey: "\(prefix).top_p")
        }

        if let effort = settings.reasoningEffort {
            defaults.set(effort.rawValue, forKey: "\(prefix).reasoning_effort")
        } else {
            defaults.removeObject(forKey: "\(prefix).reasoning_effort")
        }
    }

    private static func loadSettings(defaults: UserDefaults, prefix: String) -> LLMGenerationSettings {
        let maxTokens = defaults.object(forKey: "\(prefix).max_tokens") as? Int
        let temp = defaults.object(forKey: "\(prefix).temperature") as? Double
        let topP = defaults.object(forKey: "\(prefix).top_p") as? Double
        let effortRaw = defaults.string(forKey: "\(prefix).reasoning_effort")
        let effort = effortRaw.flatMap { ReasoningEffort(rawValue: $0) }
        let length = OutputLength(rawValue: defaults.string(forKey: "\(prefix).output_length") ?? "") ?? .medium

        return LLMGenerationSettings(
            maxOutputTokens: maxTokens,
            temperature: temp,
            topP: topP,
            reasoningEffort: effort,
            outputLength: length
        )
    }
}
