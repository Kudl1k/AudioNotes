import Foundation

enum ReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

struct LLMModelCapabilities: Equatable, Sendable, Codable {
    var input: LLMInputCapabilities = LLMInputCapabilities()
    var supportsTemperature: Bool
    var supportsTopP: Bool
    var supportsMaxOutputTokens: Bool
    var supportsReasoningEffort: Bool
    var supportsStreaming: Bool
    var supportsStructuredOutput: Bool
    var minTemperature: Double
    var maxTemperature: Double
    var defaultTemperature: Double?

    init(
        supportsTemperature: Bool = true,
        supportsTopP: Bool = true,
        supportsMaxOutputTokens: Bool = true,
        supportsReasoningEffort: Bool = false,
        supportsStreaming: Bool = true,
        supportsStructuredOutput: Bool = true,
        minTemperature: Double = 0.0,
        maxTemperature: Double = 2.0,
        defaultTemperature: Double? = 0.7
    ) {
        self.supportsTemperature = supportsTemperature
        self.supportsTopP = supportsTopP
        self.supportsMaxOutputTokens = supportsMaxOutputTokens
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsStreaming = supportsStreaming
        self.supportsStructuredOutput = supportsStructuredOutput
        self.minTemperature = minTemperature
        self.maxTemperature = maxTemperature
        self.defaultTemperature = defaultTemperature
    }

    static func capabilities(for model: String, provider: LLMProviderID) -> LLMModelCapabilities {
        var result = generationCapabilities(for: model, provider: provider)
        result.input = .known(model: model, provider: provider)
        return result
    }

    private static func generationCapabilities(for model: String, provider: LLMProviderID) -> LLMModelCapabilities {
        switch provider {
        case .ollama:
            return OllamaModelDescriptor(id: model, size: nil, vision: false, contextWindow: nil).capabilities(contextLimit: 16_384)
        case .llamaCpp:
            var result = LLMModelCapabilities(defaultTemperature: 0.7)
            var input = LLMInputCapabilities.known(model: model, provider: provider)
            input.contextWindowTokens = 16_384
            result.input = input
            return result
        case .mock:
            return LLMModelCapabilities(
                supportsTemperature: true,
                supportsTopP: true,
                supportsMaxOutputTokens: true,
                supportsReasoningEffort: false,
                supportsStreaming: true,
                supportsStructuredOutput: true,
                minTemperature: 0.0,
                maxTemperature: 2.0,
                defaultTemperature: 0.7
            )
        case .openAI:
            let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // OpenAI o1, o3, and future reasoning models:
            // official docs: do not support temperature or top_p; support reasoning_effort and max_completion_tokens
            if lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
                return LLMModelCapabilities(
                    supportsTemperature: false,
                    supportsTopP: false,
                    supportsMaxOutputTokens: true,
                    supportsReasoningEffort: true,
                    supportsStreaming: true,
                    supportsStructuredOutput: true,
                    minTemperature: 1.0,
                    maxTemperature: 1.0,
                    defaultTemperature: nil
                )
            }

            // GPT-4o, GPT-4o-mini, GPT-4-turbo, etc.
            return LLMModelCapabilities(
                supportsTemperature: true,
                supportsTopP: true,
                supportsMaxOutputTokens: true,
                supportsReasoningEffort: false,
                supportsStreaming: true,
                supportsStructuredOutput: true,
                minTemperature: 0.0,
                maxTemperature: 2.0,
                defaultTemperature: 0.7
            )
        case .anthropic:
            // Claude Code's print interface does not expose API sampling/token-ceiling controls.
            return LLMModelCapabilities(supportsTemperature: false, supportsTopP: false, supportsMaxOutputTokens: false,
                                        supportsStreaming: true, supportsStructuredOutput: true, defaultTemperature: nil)
        case .gemini:
            return LLMModelCapabilities(
                supportsTemperature: true,
                supportsTopP: true,
                supportsMaxOutputTokens: true,
                supportsReasoningEffort: false,
                supportsStreaming: true,
                supportsStructuredOutput: true,
                minTemperature: 0,
                maxTemperature: 1,
                defaultTemperature: 0.7
            )
        }
    }
}
