import Foundation

struct OpenAITokenUsage: Codable, Sendable {
    var prompt_tokens: Int?
    var completion_tokens: Int?
    var total_tokens: Int?
    var prompt_tokens_details: InputDetails?
    var completion_tokens_details: OutputDetails?
    struct InputDetails: Codable, Sendable { var cached_tokens: Int? }
    struct OutputDetails: Codable, Sendable { var reasoning_tokens: Int? }
    var normalized: GenerationUsage {
        GenerationUsage(inputTokens: prompt_tokens, outputTokens: completion_tokens, totalTokens: total_tokens,
                        cachedInputTokens: prompt_tokens_details?.cached_tokens,
                        reasoningTokens: completion_tokens_details?.reasoning_tokens)
    }
}
struct OpenAIStreamUsage: Decodable { var usage: OpenAITokenUsage? }

struct UsageAggregation {
    static func cost(_ costs: [UsageCost], billing: BillingKind) -> UsageCost {
        if billing == .local { return UsageCost(amount: Money(amount: 0), billingKind: billing, status: .free) }
        if billing == .subscription { return UsageCost(amount: nil, billingKind: billing, status: .includedWithPlan) }
        guard !costs.isEmpty, costs.allSatisfy({ $0.amount != nil }),
              let currency = costs.first?.amount?.currency,
              costs.allSatisfy({ $0.amount?.currency == currency }) else {
            return UsageCost(amount: nil, billingKind: billing,
                status: costs.contains { $0.status == .unknownPricing } ? .unknownPricing : .unavailable)
        }
        return UsageCost(amount: Money(amount: costs.reduce(Decimal.zero) { $0 + ($1.amount?.amount ?? 0) }, currency: currency),
                         billingKind: billing, status: costs.allSatisfy { $0.status == .exactFromProvider } ? .exactFromProvider : costs.contains { $0.status == .estimated } ? .estimated : .calculated)
    }
}

/// Captures pricing before requests and accumulates all internal calls in one persisted operation.
@MainActor
final class OperationUsageTracker {
    let generation: GenerationRecord
    let catalog: ProviderPricingCatalog
    let billing: BillingKind
    private var pending: [UUID: Date] = [:]
    private let persist: @MainActor () -> Void

    init(generation: GenerationRecord, catalog: ProviderPricingCatalog = .bundled, persist: @escaping @MainActor () -> Void = {}) {
        self.persist = persist
        self.generation = generation
        self.catalog = catalog
        billing = generation.billingKind
        generation.updateCost()
    }

    func beginRequest(at started: Date = .now) -> UUID {
        let id = UUID()
        pending[id] = started
        let pricing = catalog.snapshot(provider: generation.providerIDRaw ?? "", model: generation.modelID ?? "",
            operation: GenerationFeature(rawValue: generation.featureRaw) ?? .chat, at: started)
        generation.requests.append(RequestUsageRecord(id: id, startedAt: started, modelID: generation.modelID,
            cost: CostCalculator().calculate(pricing: pricing, billing: billing), succeeded: false))
        generation.updateCost()
        persist()
        return id
    }

    func discardUnsentRequest(_ id: UUID) {
        pending.removeValue(forKey: id)
        generation.requests.removeAll { $0.id == id }
        generation.updateCost()
        persist()
    }

    func finishRequest(_ id: UUID, usage: GenerationUsage? = nil, transcription: TranscriptionUsage? = nil,
                       model: String? = nil, succeeded: Bool, providerReportedCost: Money? = nil, providerCostSource: String? = nil) {
        guard let started = pending.removeValue(forKey: id) else { return }
        let pricing = model == nil || model == generation.modelID ? generation.requests.first { $0.id == id }?.cost.pricingSnapshot : catalog.snapshot(
            provider: generation.providerIDRaw ?? "", model: model!,
            operation: GenerationFeature(rawValue: generation.featureRaw) ?? .chat, at: started)
        let cost = CostCalculator().calculate(usage: usage, transcription: transcription, pricing: pricing, billing: billing,
            providerReportedCost: providerReportedCost, source: providerCostSource)
        var requests = generation.requests
        if let index = requests.firstIndex(where: { $0.id == id }) {
            requests[index] = RequestUsageRecord(id: id, startedAt: started, modelID: model ?? generation.modelID,
                usage: usage, transcriptionUsage: transcription, cost: cost, succeeded: succeeded)
            generation.requests = requests
        }
        if generation.modelID == nil { generation.modelID = model }
        generation.updateCost()
        persist()
    }

    func finish(status: GenerationStatus) {
        for id in Array(pending.keys) { finishRequest(id, succeeded: false) }
        generation.statusRaw = status.rawValue
        generation.durationSeconds = max(0, Date.now.timeIntervalSince(generation.startedAt))
        generation.updateCost()
    }
}

@MainActor
final class UsageTrackingLLMProvider: LLMProvider {
    let base: any LLMProvider
    let tracker: OperationUsageTracker
    var id: LLMProviderID { base.id }
    var displayName: String { base.displayName }
    var modelID: String? { base.modelID }
    var modelDisplayName: String? { base.modelDisplayName }
    var authenticationMethod: ProviderAuthenticationMethod? { base.authenticationMethod }
    var supportsSourceSummaries: Bool { base.supportsSourceSummaries }
    var inputCapabilities: LLMInputCapabilities { base.inputCapabilities }
    var executionLocation: ProviderExecutionLocation { base.executionLocation }
    var billingKind: BillingKind { base.billingKind }
    init(base: any LLMProvider, tracker: OperationUsageTracker) { self.base = base; self.tracker = tracker }
    func prepareForGeneration() async throws { try await base.prepareForGeneration() }
    func summaryRequestFits(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Bool {
        try await base.summaryRequestFits(context: context, configuration: configuration)
    }

    func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
        let id = tracker.beginRequest()
        do {
            let result = try await base.generateSummary(transcript: transcript, configuration: configuration)
            tracker.finishRequest(id, usage: result.reportedUsage, model: base.id == .onDevice ? base.modelID : result.modelName, succeeded: true)
            return result
        } catch {
            if ProviderRequestFailure.isKnownPreflight(error) { tracker.discardUnsentRequest(id) }
            else { tracker.finishRequest(id, usage: (error as? ProviderUsageError)?.usage, succeeded: false) }
            throw (error as? ProviderUsageError)?.underlying ?? error
        }
    }

    func generateSourceSummary(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Summary {
        let id = tracker.beginRequest()
        tracker.generation.imageInputCount += context.images.count
        do {
            let result = try await base.generateSourceSummary(context: context, configuration: configuration)
            tracker.finishRequest(id, usage: result.reportedUsage, model: base.id == .onDevice ? base.modelID : result.modelName, succeeded: true)
            return result
        } catch {
            if ProviderRequestFailure.isKnownPreflight(error) { tracker.discardUnsentRequest(id) }
            else { tracker.finishRequest(id, usage: (error as? ProviderUsageError)?.usage, succeeded: false) }
            throw (error as? ProviderUsageError)?.underlying ?? error
        }
    }

    func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        try await base.streamChat(messages: messages, context: context)
    }
}

struct ProviderUsageError: Error, @unchecked Sendable {
    var underlying: any Error
    var usage: GenerationUsage?
    static func preserving(_ underlying: any Error, usage: GenerationUsage?) -> any Error {
        if let usage { return ProviderUsageError(underlying: underlying, usage: usage) }
        return underlying
    }
}


struct ResponsesTokenUsage: Decodable {
    var input_tokens: Int?
    var output_tokens: Int?
    var total_tokens: Int?
    var input_tokens_details: OpenAITokenUsage.InputDetails?
    var output_tokens_details: OpenAITokenUsage.OutputDetails?
    var normalized: GenerationUsage {
        GenerationUsage(inputTokens: input_tokens, outputTokens: output_tokens, totalTokens: total_tokens,
            cachedInputTokens: input_tokens_details?.cached_tokens, reasoningTokens: output_tokens_details?.reasoning_tokens)
    }
    static func from(event: [String: Any]) -> GenerationUsage? {
        // Missing or null usage is unavailable. Invalid JSON objects can raise an
        // Objective-C exception during serialization, which Swift's try? cannot catch.
        guard let response = event["response"] as? [String: Any],
              let usage = response["usage"] as? [String: Any],
              JSONSerialization.isValidJSONObject(usage),
              let data = try? JSONSerialization.data(withJSONObject: usage) else { return nil }
        return (try? JSONDecoder().decode(Self.self, from: data))?.normalized
    }
}


struct ProviderRequestFailure {
    static func isKnownPreflight(_ error: any Error) -> Bool {
        if let local = error as? LocalAIError, [.privacyBlocked, .invalidEndpoint, .cloudModel].contains(local) { return true }
        if let cli = error as? ClaudeCLIError, [.notInstalled, .notSignedIn, .unsupportedAuthentication, .launchFailed, .invalidModel].contains(cli) { return true }
        guard let error = error as? LLMError else { return false }
        switch error {
        case .missingAPIKey, .providerUnavailable, .contextTooLarge, .transcriptEmpty,
             .chatGPTNotSignedIn, .chatGPTPlanNotEnabled: return true
        default: return false
        }
    }
}
