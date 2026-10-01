import Foundation

enum OutputLength: String, CaseIterable, Codable, Identifiable, Sendable {
    case concise, short, medium, long, detailed
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum OutputLengthInstructionBuilder {
    static func instruction(for length: OutputLength) -> String {
        switch length {
        case .concise: "Give a very concise answer. Include only the most important information."
        case .short: "Keep the response brief and focused."
        case .medium: "Provide a balanced amount of detail."
        case .long: "Provide a thorough response with relevant details."
        case .detailed: "Provide a comprehensive response and preserve important nuance, examples, decisions and supporting information."
        }
    }
}

struct LLMGenerationSettings: Equatable, Sendable, Codable {
    var outputLength: OutputLength
    var maxOutputTokens: Int?
    var temperature: Double?
    var topP: Double?
    var reasoningEffort: ReasoningEffort?

    init(
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        outputLength: OutputLength = .medium
    ) {
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.topP = topP
        self.reasoningEffort = reasoningEffort
        self.outputLength = outputLength
    }

    /// Filters and bounds-checks parameters strictly based on the model's capabilities.
    /// Unsupported parameters are stripped (set to nil) to prevent API errors.
    func sanitized(for capabilities: LLMModelCapabilities) -> LLMGenerationSettings {
        var sanitizedTokens: Int? = nil
        if capabilities.supportsMaxOutputTokens, let tokens = maxOutputTokens, tokens > 0 {
            sanitizedTokens = tokens
        }

        var sanitizedTemperature: Double? = nil
        if capabilities.supportsTemperature, let temp = temperature {
            sanitizedTemperature = min(max(temp, capabilities.minTemperature), capabilities.maxTemperature)
        }

        var sanitizedTopP: Double? = nil
        if capabilities.supportsTopP, let p = topP {
            sanitizedTopP = min(max(p, 0.0), 1.0)
        }

        var sanitizedEffort: ReasoningEffort? = nil
        if capabilities.supportsReasoningEffort {
            sanitizedEffort = reasoningEffort
        }

        return LLMGenerationSettings(
            maxOutputTokens: sanitizedTokens,
            temperature: sanitizedTemperature,
            topP: sanitizedTopP,
            reasoningEffort: sanitizedEffort,
            outputLength: outputLength
        )
    }

    /// Returns true if all settings are at default / unset.
    var isDefault: Bool {
        maxOutputTokens == nil && temperature == nil && topP == nil && reasoningEffort == nil && outputLength == .medium
    }
}
