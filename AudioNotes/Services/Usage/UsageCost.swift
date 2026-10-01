import Foundation

struct Currency: RawRepresentable, Codable, Hashable, Sendable {
    var rawValue: String
    static let usd = Currency(rawValue: "USD")
}

struct Money: Codable, Equatable, Sendable {
    var amount: Decimal
    var currency: Currency = .usd
}

enum BillingKind: String, Codable, Sendable {
    case meteredAPI, subscription, local, unknown

    static func resolve(provider: String?, authentication: ProviderAuthenticationMethod?) -> Self {
        if provider == "mock" { return .local }
        if provider == "openAI", authentication == .chatGPTAccount { return .subscription }
        switch authentication {
        case .apiKey, .oauth, .appAttest, .workloadIdentity: return .meteredAPI
        default: return .unknown
        }
    }
}

enum CostCalculationStatus: String, Codable, Sendable {
    case exactFromProvider, calculated, estimated, includedWithPlan, free, unavailable, unknownPricing
}

struct UsageCost: Codable, Equatable, Sendable {
    var amount: Money?
    var billingKind: BillingKind
    var status: CostCalculationStatus
    var pricingSnapshot: PricingSnapshot?
    var providerCostSource: String?

    var displayText: String {
        if billingKind == .local { return "Local · No API charge" }
        switch status {
        case .includedWithPlan: return "Included with plan"
        case .unknownPricing: return "Pricing unavailable for this model"
        case .unavailable: return "Cost unavailable"
        default:
            guard let amount else { return "Cost unavailable" }
            return (status == .estimated ? "Estimated ~" : "") + MoneyFormatter.string(amount)
        }
    }
}

struct TranscriptionUsage: Codable, Equatable, Sendable {
    var recordingDuration: Decimal?
    var processedDuration: Decimal?
    var providerReportedDuration: Decimal?
    var providerSpecificUsage: [String: Decimal]? = nil
}

/// One entry per actual provider request, including unsuccessful attempts.
struct RequestUsageRecord: Codable, Equatable, Sendable {
    var id = UUID()
    var startedAt: Date
    var modelID: String?
    var usage: GenerationUsage?
    var transcriptionUsage: TranscriptionUsage?
    var cost: UsageCost
    var succeeded: Bool
}

struct CostCalculator: Sendable {
    func calculate(usage: GenerationUsage? = nil, transcription: TranscriptionUsage? = nil,
                   pricing: PricingSnapshot?, billing: BillingKind,
                   providerReportedCost: Money? = nil, source: String? = nil,
                   estimated: Bool = false) -> UsageCost {
        func result(_ amount: Money? = nil, _ status: CostCalculationStatus) -> UsageCost {
            UsageCost(amount: amount, billingKind: billing, status: status, pricingSnapshot: pricing, providerCostSource: source)
        }
        if let providerReportedCost { return result(providerReportedCost, .exactFromProvider) }
        if billing == .local { return result(Money(amount: 0), .free) }
        if billing == .subscription { return result(nil, .includedWithPlan) }
        guard billing == .meteredAPI else { return result(nil, .unavailable) }
        guard let pricing else { return result(nil, .unknownPricing) }
        if let rate = pricing.audioMinutePrice {
            guard let seconds = transcription?.providerReportedDuration ?? transcription?.processedDuration,
                  seconds >= 0 else { return result(nil, .unavailable) }
            return result(Money(amount: seconds * rate / 60, currency: pricing.currency), estimated ? .estimated : .calculated)
        }
        guard let usage, let input = usage.inputTokens, let output = usage.outputTokens,
              input >= 0, output >= 0,
              let inputRate = pricing.inputTokenPrice, let outputRate = pricing.outputTokenPrice else {
            return result(nil, .unavailable)
        }
        let cached = usage.cachedInputTokens ?? 0
        let writes = usage.cacheWriteInputTokens ?? 0
        guard cached >= 0, writes >= 0 else { return result(nil, .unavailable) }
        let totalInput = usage.inputIncludesCachedTokens ? Decimal(input) : Decimal(input) + Decimal(cached) + Decimal(writes)
        if let maximum = pricing.maximumInputTokens, totalInput > Decimal(maximum) { return result(nil, .unknownPricing) }
        let regular = usage.inputIncludesCachedTokens ? input - cached - writes : input
        guard writes == 0 || (usage.cacheWriteDurationSeconds != nil && usage.cacheWriteDurationSeconds == pricing.cacheWriteDurationSeconds),
              regular >= 0, cached == 0 || pricing.cachedInputPrice != nil,
              writes == 0 || pricing.cacheWritePrice != nil else { return result(nil, .unavailable) }
        // Reasoning tokens are included in normalized output; never add them twice.
        let amount = (Decimal(regular) * inputRate + Decimal(output) * outputRate
                      + Decimal(cached) * (pricing.cachedInputPrice ?? 0)
                      + Decimal(writes) * (pricing.cacheWritePrice ?? 0)) / 1_000_000
        return result(Money(amount: amount, currency: pricing.currency), estimated ? .estimated : .calculated)
    }
}

struct MoneyFormatter {
    static func string(_ money: Money, locale: Locale = .current) -> String {
        let value = money.amount
        if value > 0 && value < Decimal(string: "0.001")! {
            return "<" + formatted(Decimal(string: "0.001")!, currency: money.currency, digits: 3, locale: locale)
        }
        let digits = value == 0 || value >= 1 ? 2 : value >= Decimal(string: "0.01")! ? 3 : 4
        return formatted(value, currency: money.currency, digits: digits, locale: locale)
    }

    private static func formatted(_ value: Decimal, currency: Currency, digits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currency.rawValue
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value) \(currency.rawValue)"
    }
}
