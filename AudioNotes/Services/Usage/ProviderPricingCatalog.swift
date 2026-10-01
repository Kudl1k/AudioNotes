import Foundation

/// USD standard, synchronous, first-party API pricing. No tools, batch or regional modifiers.
struct PricingSnapshot: Codable, Equatable, Sendable {
    var providerID: String
    var modelID: String
    var operation: GenerationFeature
    var effectiveFrom: Date
    var currency: Currency = .usd
    var inputTokenPrice: Decimal? = nil // per million tokens
    var outputTokenPrice: Decimal? = nil
    var cachedInputPrice: Decimal? = nil
    var cacheWritePrice: Decimal? = nil // five minute cache writes only
    var audioMinutePrice: Decimal? = nil
    var maximumInputTokens: Int? = nil
    var cacheWriteDurationSeconds: Int? = nil
    var sourceURL: URL
    var verifiedAt: Date
}

typealias PricingDefinition = PricingSnapshot

struct ProviderPricingCatalog: Sendable {
    var definitions: [PricingDefinition]

    func snapshot(provider: String, model: String, operation: GenerationFeature, at date: Date) -> PricingSnapshot? {
        definitions.filter { $0.providerID == provider && $0.modelID == model && $0.operation == operation && $0.effectiveFrom <= date }
            .max { $0.effectiveFrom < $1.effectiveFrom }
    }

    // Verification date is the earliest date this release knows these rates apply.
    // Deliberately do not backdate current rates to legacy generations.
    static let verifiedAt = ISO8601DateFormatter().date(from: "2026-09-30T00:00:00Z")!
    static let bundled: Self = {
        let date = verifiedAt
        var entries: [PricingDefinition] = []
        func tokens(_ provider: String, _ model: String, _ input: String, _ output: String, _ cache: String, _ source: String, write: String? = nil) {
            for operation in [GenerationFeature.summary, .chat] {
                entries.append(PricingDefinition(providerID: provider, modelID: model, operation: operation,
                    effectiveFrom: date, inputTokenPrice: Decimal(string: input), outputTokenPrice: Decimal(string: output),
                    cachedInputPrice: Decimal(string: cache), cacheWritePrice: write.flatMap { Decimal(string: $0) },
                    sourceURL: URL(string: source)!, verifiedAt: date))
                if provider == "anthropic" {
                    entries[entries.count - 1].maximumInputTokens = 200_000
                    entries[entries.count - 1].cacheWriteDurationSeconds = 300
                }
            }
        }
        tokens("openAI", "gpt-4o-mini", "0.15", "0.60", "0.075", "https://developers.openai.com/api/docs/models/gpt-4o-mini")
        tokens("openAI", "gpt-4o-mini-2024-07-18", "0.15", "0.60", "0.075", "https://developers.openai.com/api/docs/models/gpt-4o-mini")
        tokens("openAI", "gpt-4o", "2.50", "10", "1.25", "https://developers.openai.com/api/docs/models/gpt-4o")
        tokens("anthropic", "claude-sonnet-4-5", "3", "15", "0.30", "https://platform.claude.com/docs/en/about-claude/pricing", write: "3.75")
        tokens("anthropic", "claude-haiku-4-5", "1", "5", "0.10", "https://platform.claude.com/docs/en/about-claude/pricing", write: "1.25")
        tokens("gemini", "gemini-2.5-flash", "0.30", "2.50", "0.03", "https://ai.google.dev/gemini-api/docs/pricing")
        entries.append(PricingDefinition(providerID: "openAI", modelID: "whisper-1", operation: .transcription,
            effectiveFrom: date, audioMinutePrice: Decimal(string: "0.006"),
            sourceURL: URL(string: "https://developers.openai.com/api/docs/models/whisper-1")!, verifiedAt: date))
        return Self(definitions: entries)
    }()
}
