import Foundation

struct TranscriptionCostEstimate {
    var cost: UsageCost
    var partCount: Int?
    var processedDuration: Decimal?
    var displayText: String {
        let parts = partCount.map { " · approximately \($0) parts" } ?? ""
        return cost.displayText + parts
    }
}

struct CostEstimator {
    func transcription(provider: String?, model: String?, authentication: ProviderAuthenticationMethod?,
                       duration: TimeInterval, fileSize: Int?, at date: Date = .now,
                       catalog: ProviderPricingCatalog = .bundled, billingOverride: BillingKind? = nil) -> TranscriptionCostEstimate {
        let billing = billingOverride ?? BillingKind.resolve(provider: provider, authentication: authentication)
        let pricing = catalog.snapshot(provider: provider ?? "", model: model ?? "", operation: .transcription, at: date)
        var processed: Decimal?
        var parts: Int?
        if provider == "openAI", model == "whisper-1", let fileSize,
           let plan = try? OpenAIAudioSplitPlan.make(duration: duration, fileSize: fileSize) {
            parts = plan.ranges.count
            processed = plan.ranges.reduce(Decimal.zero) { $0 + (Decimal(string: String($1.duration)) ?? 0) }
        } else if duration.isFinite && duration > 0 {
            processed = Decimal(string: String(duration))
        }
        let usage = TranscriptionUsage(recordingDuration: Decimal(string: String(duration)), processedDuration: processed)
        return TranscriptionCostEstimate(cost: CostCalculator().calculate(transcription: usage, pricing: pricing,
            billing: billing, estimated: true), partCount: parts, processedDuration: processed)
    }
}

struct EstimatedCostRange: Codable, Equatable, Sendable {
    var minimum: Money
    var maximum: Money
    var approximateInputTokens: Int
    var outputTokenCeiling: Int
    var pricingSnapshot: PricingSnapshot
    var displayText: String {
        "Estimated \(MoneyFormatter.string(minimum))–\(MoneyFormatter.string(maximum)) · ~\(approximateInputTokens) input tokens · up to \(outputTokenCeiling) output tokens"
    }
}

extension CostEstimator {
    /// A budget range, using the caller's explicit safety ceiling rather than mapping OutputLength to tokens.
    func llmBudget(provider: String, model: String, operation: GenerationFeature,
                   approximateInputTokens: Int, outputTokenCeiling: Int?, at date: Date = .now,
                   catalog: ProviderPricingCatalog = .bundled) -> EstimatedCostRange? {
        guard approximateInputTokens > 0, let ceiling = outputTokenCeiling, ceiling > 0,
              let pricing = catalog.snapshot(provider: provider, model: model, operation: operation, at: date),
              let inputRate = pricing.inputTokenPrice, let outputRate = pricing.outputTokenPrice else { return nil }
        let input = Decimal(approximateInputTokens)
        return EstimatedCostRange(minimum: Money(amount: input * (pricing.cachedInputPrice ?? inputRate) / 1_000_000),
            maximum: Money(amount: (input * inputRate + Decimal(ceiling) * outputRate) / 1_000_000),
            approximateInputTokens: approximateInputTokens, outputTokenCeiling: ceiling, pricingSnapshot: pricing)
    }
}
