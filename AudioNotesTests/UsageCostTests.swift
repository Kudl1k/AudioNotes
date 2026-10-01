import Foundation
import SwiftData
import Testing
@testable import AudioNotes

struct UsageCostTests {
    @Test(arguments: [
        #"{}"#,
        #"{"response":null}"#,
        #"{"response":{}}"#,
        #"{"response":{"usage":null}}"#,
        #"{"response":{"usage":"unavailable"}}"#,
        #"{"response":{"usage":42}}"#,
        #"{"response":{"usage":true}}"#,
        #"{"response":{"usage":[]}}"#,
        #"{"response":{"usage":{"input_tokens":"invalid"}}}"#
    ])
    func responsesMissingOrMalformedUsageIsUnavailable(json: String) throws {
        let event = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(ResponsesTokenUsage.from(event: event) == nil)
    }

    @Test func responsesUsageRejectsNonJSONDictionary() {
        let event: [String: Any] = ["response": ["usage": ["input_tokens": Date()]]]
        #expect(ResponsesTokenUsage.from(event: event) == nil)
    }

    @Test func responsesUsagePreservesReportedTokenCounts() throws {
        let json = #"{"response":{"usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120,"input_tokens_details":{"cached_tokens":40},"output_tokens_details":{"reasoning_tokens":10}}}}"#
        let event = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let usage = try #require(ResponsesTokenUsage.from(event: event))
        #expect(usage.inputTokens == 100)
        #expect(usage.outputTokens == 20)
        #expect(usage.totalTokens == 120)
        #expect(usage.cachedInputTokens == 40)
        #expect(usage.reasoningTokens == 10)
    }

    let calculator = CostCalculator()
    func decimal(_ value: String) -> Decimal { Decimal(string: value)! }
    func pricing(input: String = "2", output: String = "10", cache: String = "0.5") -> PricingSnapshot {
        PricingSnapshot(providerID: "openAI", modelID: "fixture", operation: .summary,
            effectiveFrom: Date(timeIntervalSince1970: 0), inputTokenPrice: decimal(input),
            outputTokenPrice: decimal(output), cachedInputPrice: decimal(cache),
            sourceURL: URL(string: "https://example.invalid/pricing")!, verifiedAt: .now)
    }

    @Test func tokenCostUsesDecimal() {
        let cost = calculator.calculate(usage: GenerationUsage(inputTokens: 10_000, outputTokens: 2_000), pricing: pricing(), billing: .meteredAPI)
        #expect(cost.amount?.amount == decimal("0.04"))
        #expect(cost.status == .calculated)
    }

    @Test func cacheIsNotCountedTwice() {
        let usage = GenerationUsage(inputTokens: 10_000, outputTokens: 2_000, cachedInputTokens: 4_000)
        let cost = calculator.calculate(usage: usage, pricing: pricing(), billing: .meteredAPI)
        #expect(cost.amount?.amount == decimal("0.034"))
        var separated = usage
        separated.inputTokens = 6_000
        separated.inputIncludesCachedTokens = false
        #expect(calculator.calculate(usage: separated, pricing: pricing(), billing: .meteredAPI).amount == cost.amount)
    }

    @Test func missingAndInvalidUsageAreUnavailable() {
        #expect(calculator.calculate(pricing: pricing(), billing: .meteredAPI).status == .unavailable)
        #expect(calculator.calculate(usage: GenerationUsage(inputTokens: -1, outputTokens: 20), pricing: pricing(), billing: .meteredAPI).amount == nil)
        #expect(calculator.calculate(usage: GenerationUsage(inputTokens: 1, outputTokens: 20, cachedInputTokens: 2), pricing: pricing(), billing: .meteredAPI).amount == nil)
        #expect(calculator.calculate(pricing: nil, billing: .meteredAPI).status == .unknownPricing)
    }

    @Test func unknownCacheRateDoesNotInventPrice() {
        var rates = pricing(); rates.cachedInputPrice = nil
        let usage = GenerationUsage(inputTokens: 100, outputTokens: 10, cachedInputTokens: 20)
        #expect(calculator.calculate(usage: usage, pricing: rates, billing: .meteredAPI).amount == nil)
    }

    @Test func reasoningIncludedInOutputIsNotAddedAgain() {
        let usage = GenerationUsage(inputTokens: 10_000, outputTokens: 2_000, reasoningTokens: 1_000)
        #expect(calculator.calculate(usage: usage, pricing: pricing(), billing: .meteredAPI).amount?.amount == decimal("0.04"))
    }

    @Test func authMethodsHaveDistinctBilling() {
        #expect(BillingKind.resolve(provider: "openAI", authentication: .apiKey) == .meteredAPI)
        #expect(BillingKind.resolve(provider: "openAI", authentication: .chatGPTAccount) == .subscription)
        #expect(BillingKind.resolve(provider: "gemini", authentication: .oauth) == .meteredAPI)
        #expect(BillingKind.resolve(provider: "anthropic", authentication: .appAttest) == .meteredAPI)
        #expect(BillingKind.resolve(provider: nil, authentication: nil) == .unknown)
        #expect(calculator.calculate(pricing: nil, billing: .subscription).displayText == "Included with plan")
        #expect(calculator.calculate(pricing: nil, billing: .subscription).amount == nil)
        #expect(calculator.calculate(pricing: nil, billing: .local).amount?.amount == 0)
        #expect(calculator.calculate(pricing: nil, billing: .local).status == .free)
        #expect(calculator.calculate(pricing: nil, billing: .unknown).displayText == "Cost unavailable")
    }

    @Test func providerMonetaryCostTakesPrecedence() {
        let cost = calculator.calculate(pricing: nil, billing: .meteredAPI,
            providerReportedCost: Money(amount: decimal("0.007")), source: "provider receipt")
        #expect(cost.status == .exactFromProvider)
        #expect(cost.amount?.amount == decimal("0.007"))
    }

    @Test func moneyDoesNotAccumulateFloatingPointError() {
        let costs = (0..<10_000).map { _ in UsageCost(amount: Money(amount: decimal("0.0001")), billingKind: .meteredAPI, status: .calculated) }
        #expect(UsageAggregation.cost(costs, billing: .meteredAPI).amount?.amount == 1)
        #expect(UsageAggregation.cost([UsageCost(amount: Money(amount: decimal("123456789.123456789")), billingKind: .meteredAPI, status: .calculated)], billing: .meteredAPI).amount?.amount == decimal("123456789.123456789"))
    }

    @Test func adaptiveCurrencyFormatting() {
        let locale = Locale(identifier: "en_US")
        #expect(MoneyFormatter.string(Money(amount: 0), locale: locale) == "$0.00")
        #expect(MoneyFormatter.string(Money(amount: decimal("1.24")), locale: locale) == "$1.24")
        #expect(MoneyFormatter.string(Money(amount: decimal("0.014")), locale: locale) == "$0.014")
        #expect(MoneyFormatter.string(Money(amount: decimal("0.0032")), locale: locale) == "$0.0032")
        #expect(MoneyFormatter.string(Money(amount: decimal("0.0001")), locale: locale) == "<$0.001")
        #expect(MoneyFormatter.string(Money(amount: decimal("1.24"), currency: Currency(rawValue: "EUR")), locale: locale).contains("1.24"))
    }

    @Test(arguments: [600, 3600]) func durationBilling(seconds: Int) {
        var rates = pricing(); rates.audioMinutePrice = decimal("0.006")
        let usage = TranscriptionUsage(recordingDuration: Decimal(seconds), processedDuration: Decimal(seconds))
        #expect(calculator.calculate(transcription: usage, pricing: rates, billing: .meteredAPI).amount?.amount == Decimal(seconds) / 60 * decimal("0.006"))
    }

    @Test func billableDurationIncludesOverlapAndRetry() {
        var rates = pricing(); rates.audioMinutePrice = decimal("0.006")
        let requests = [600, 604, 604].map { seconds in
            calculator.calculate(transcription: TranscriptionUsage(recordingDuration: 1200, processedDuration: Decimal(seconds)), pricing: rates, billing: .meteredAPI)
        }
        #expect(UsageAggregation.cost(requests, billing: .meteredAPI).amount?.amount == decimal("0.1808"))
        let known = calculator.calculate(transcription: TranscriptionUsage(recordingDuration: 1200, processedDuration: 604, providerReportedDuration: 605), pricing: rates, billing: .meteredAPI)
        #expect(known.amount?.amount == decimal("0.0605"))
    }

    @Test func incompleteMultipartNeverDisplaysZero() {
        var rates = pricing(); rates.audioMinutePrice = decimal("0.006")
        let known = calculator.calculate(transcription: TranscriptionUsage(processedDuration: 600), pricing: rates, billing: .meteredAPI)
        let unknown = calculator.calculate(pricing: rates, billing: .meteredAPI)
        #expect(UsageAggregation.cost([known, unknown], billing: .meteredAPI).amount == nil)
        #expect(unknown.displayText == "Cost unavailable")
    }

    @Test func currentCatalogIsVersionedAndDoesNotBackdate() {
        let catalog = ProviderPricingCatalog.bundled
        #expect(catalog.snapshot(provider: "openAI", model: "whisper-1", operation: .transcription, at: .now)?.audioMinutePrice == decimal("0.006"))
        #expect(catalog.snapshot(provider: "openAI", model: "new-model", operation: .chat, at: .now) == nil)
        #expect(catalog.snapshot(provider: "openAI", model: "gpt-4o", operation: .chat, at: Date(timeIntervalSince1970: 0)) == nil)
        #expect(catalog.definitions.allSatisfy { $0.sourceURL.scheme == "https" && $0.verifiedAt == ProviderPricingCatalog.verifiedAt })
    }

    @Test func officialUsageNormalization() throws {
        let data = Data(#"{"prompt_tokens":10000,"completion_tokens":2000,"total_tokens":12000,"prompt_tokens_details":{"cached_tokens":4000},"completion_tokens_details":{"reasoning_tokens":1000}}"#.utf8)
        let usage = try JSONDecoder().decode(OpenAITokenUsage.self, from: data).normalized
        #expect(usage.cachedInputTokens == 4_000)
        #expect(usage.reasoningTokens == 1_000)
        #expect(usage.inputTokens == 10_000)
    }

    @Test func transcriptionEstimateIsSeparateAndCountsParts() {
        let estimate = CostEstimator().transcription(provider: "openAI", model: "whisper-1", authentication: .apiKey,
            duration: 3600, fileSize: 100_000_000)
        #expect(estimate.cost.status == .estimated)
        #expect(estimate.partCount == 6)
        #expect(estimate.cost.amount?.amount == decimal("0.36"))
        #expect(estimate.processedDuration == 3600)
    }

    @Test func timeRangesUseLocalCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Prague"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-30T22:30:00Z"))
        let today = try #require(UsageTimeRange.today.interval(now: now, calendar: calendar))
        #expect(calendar.component(.day, from: today.start) == 1)
        #expect(calendar.component(.month, from: today.start) == 10)
        #expect(UsageTimeRange.all.interval(now: now, calendar: calendar) == nil)
    }
}

@MainActor
struct UsageTrackingTests {
    func recording() -> Recording { Recording(title: "Meeting", audioFileName: "a.m4a", originalFileName: "a.m4a", duration: 1200) }
    func generation(_ recording: Recording, feature: GenerationFeature = .summary,
                    auth: ProviderAuthenticationMethod = .apiKey, model: String = "gpt-4o-mini") -> GenerationRecord {
        GenerationRecord(recording: recording, feature: feature, provider: .openAI, model: model,
            presetName: nil, outputLength: .detailed, settings: nil, authenticationMethod: auth, status: .inProgress)
    }

    @Test func hierarchicalRequestsAggregateIntoOneGeneration() async throws {
        let recording = recording()
        let generation = generation(recording)
        let tracker = OperationUsageTracker(generation: generation)
        let provider = UsageFixtureProvider()
        let tracked = UsageTrackingLLMProvider(base: provider, tracker: tracker)
        let transcript = Transcript()
        transcript.segments = (0..<3).map { TranscriptSegment(position: $0, startTime: Double($0), endTime: Double($0 + 1), text: String(repeating: "word ", count: 200)) }
        let result = try await HierarchicalSummaryGenerator(chunker: TranscriptChunker(targetCharacters: 1000, overlapSegments: 0), singlePassLimitTokens: 1)
            .generate(transcript: transcript, configuration: SummaryConfiguration(outputLength: .detailed), provider: tracked)
        tracker.finish(status: .succeeded)
        #expect(result.chunkCount == 3)
        #expect(generation.requests.count == 4)
        #expect(generation.inputTokens == 40_000)
        #expect(generation.outputTokens == 8_000)
        #expect(generation.usageCost.amount?.amount == Decimal(string: "0.0108"))
    }

    @Test func failedRetryUsageAndCancelledUnknownAreRetained() {
        let generation = generation(recording())
        let tracker = OperationUsageTracker(generation: generation)
        tracker.finishRequest(tracker.beginRequest(), usage: GenerationUsage(inputTokens: 10_000, outputTokens: 2_000), succeeded: false)
        tracker.finishRequest(tracker.beginRequest(), usage: GenerationUsage(inputTokens: 10_000, outputTokens: 2_000), succeeded: true)
        #expect(generation.requests.count == 2)
        #expect(generation.usageCost.amount?.amount == Decimal(string: "0.0054"))
        _ = tracker.beginRequest()
        tracker.finish(status: .cancelled)
        #expect(generation.requests.count == 3)
        #expect(generation.requests.last?.cost.amount == nil)
        #expect(generation.usageCost.amount == nil)
        let totals = UsageRepository().snapshot(records: [generation]).total
        #expect(totals.knownAPIAmount == Decimal(string: "0.0054"))
        #expect(totals.unavailableRequests == 1)
    }

    @Test func historicalSnapshotSurvivesCatalogReplacementAndReload() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        var expected: UsageCost?
        do {
            let container = try workspace.storage.makeContainer()
            let context = ModelContext(container)
            let recording = recording(); context.insert(recording)
            let generation = generation(recording)
            let tracker = OperationUsageTracker(generation: generation)
            tracker.finishRequest(tracker.beginRequest(), usage: GenerationUsage(inputTokens: 10_000, outputTokens: 2_000), succeeded: true)
            tracker.finish(status: .succeeded)
            expected = generation.usageCost
            context.insert(generation); try context.save()
        }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        let generation = try #require(context.fetch(FetchDescriptor<GenerationRecord>()).first)
        var revised = try #require(generation.requests.first?.cost.pricingSnapshot)
        revised.inputTokenPrice = 100
        revised.effectiveFrom = .now
        let updated = ProviderPricingCatalog(definitions: [revised])
        #expect(updated.snapshot(provider: "openAI", model: "gpt-4o-mini", operation: .summary, at: .now)?.inputTokenPrice == 100)
        #expect(generation.usageCost == expected)
        #expect(generation.requests.first?.cost.pricingSnapshot?.inputTokenPrice == Decimal(string: "0.15"))
        let recording = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(recording.generationRecords.count == 1)
        context.delete(recording); try context.save()
        #expect(try context.fetchCount(FetchDescriptor<GenerationRecord>()) == 0)
    }

    @Test func aggregatePlanAndAPISeparately() {
        let recording = recording()
        let api = generation(recording, feature: .chat)
        let tracker = OperationUsageTracker(generation: api)
        tracker.finishRequest(tracker.beginRequest(), usage: GenerationUsage(inputTokens: 10_000, outputTokens: 2_000), succeeded: true)
        tracker.finish(status: .succeeded)
        let plan = generation(recording, feature: .chat, auth: .chatGPTAccount)
        let planTracker = OperationUsageTracker(generation: plan)
        planTracker.finishRequest(planTracker.beginRequest(), succeeded: true)
        planTracker.finish(status: .succeeded)
        let snapshot = UsageRepository().snapshot(records: [api, plan])
        #expect(snapshot.total.planRequests == 1)
        #expect(snapshot.total.knownAPIAmount == Decimal(string: "0.0027"))
        #expect(snapshot.byRecording[recording.id] == snapshot.total)
        #expect(snapshot.byFeature["chat"] == snapshot.total)
    }

    @Test func exportCostIsOptIn() {
        let recording = recording()
        let generation = generation(recording)
        let tracker = OperationUsageTracker(generation: generation)
        tracker.finishRequest(tracker.beginRequest(), usage: GenerationUsage(inputTokens: 10_000, outputTokens: 2_000), succeeded: true)
        recording.generationRecords = [generation]
        let content = ExportContentBuilder.build(from: recording)
        var options = ExportOptions()
        #expect(!MarkdownExporter().export(content: content, options: options).contains("API key"))
        options.includeAIGenerationMetadata = true
        #expect(MarkdownExporter().export(content: content, options: options).contains(MoneyFormatter.string(Money(amount: Decimal(string: "0.0027")!))))
        #expect(!PDFExporter().export(content: content, options: options).isEmpty)
    }


    @Test func summaryRetryKeepsKnownChargesInOneLogicalOperation() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = recording()
        let transcript = Transcript()
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 1, text: "A note.")]
        recording.transcript = transcript
        context.insert(recording)
        let provider = RetryingUsageFixtureProvider()
        let model = SummaryViewModel(recording: recording, resolver: FixedLLMProviderResolver(provider: provider))
        let repository = SwiftDataSummaryRepository(context: context)
        await model.generateSummary(using: repository)?.value
        #expect(recording.summary == nil)
        await model.generateSummary(using: repository)?.value
        let records = try context.fetch(FetchDescriptor<GenerationRecord>())
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.attemptCount == 2)
        #expect(record.requests.count == 2)
        #expect(record.usageCost.amount?.amount == Decimal(string: "0.0054"))
        #expect(recording.summary?.generationID == record.id)
    }

    @Test func unfinishedOperationsPreserveKnownUsageAfterRestart() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = recording(); context.insert(recording)
        let generation = generation(recording)
        let tracker = OperationUsageTracker(generation: generation)
        tracker.finishRequest(tracker.beginRequest(), usage: GenerationUsage(inputTokens: 10_000, outputTokens: 2_000), succeeded: true)
        _ = tracker.beginRequest()
        context.insert(generation); try context.save()
        try UsageRepository().markInterruptedOperations(context: context)
        #expect(generation.statusRaw == "cancelled")
        #expect(generation.requests.count == 2)
        #expect(generation.usageCost.amount == nil)
        #expect(UsageRepository().snapshot(records: [generation]).total.knownAPIAmount == Decimal(string: "0.0027"))
    }

    @Test func unknownModelStillGenerates() async throws {
        let record = generation(recording(), model: "new-model")
        let tracker = OperationUsageTracker(generation: record, catalog: ProviderPricingCatalog(definitions: []))
        let result = try await UsageTrackingLLMProvider(base: UsageFixtureProvider(), tracker: tracker)
            .generateSummary(transcript: Transcript(), configuration: SummaryConfiguration())
        #expect(result.overview == "Summary")
        #expect(record.usageCost.status == .unknownPricing)
        #expect(record.usageCost.amount == nil)
    }

    @Test func summaryBudgetUsesExplicitCeiling() {
        let estimate = CostEstimator().llmBudget(provider: "openAI", model: "gpt-4o-mini", operation: .summary,
            approximateInputTokens: 10_000, outputTokenCeiling: 2_000)
        #expect(estimate?.minimum.amount == Decimal(string: "0.00075"))
        #expect(estimate?.maximum.amount == Decimal(string: "0.0027"))
        #expect(CostEstimator().llmBudget(provider: "openAI", model: "gpt-4o-mini", operation: .summary,
            approximateInputTokens: 10_000, outputTokenCeiling: nil) == nil)
    }

    @Test func summaryHTTPResponseRetainsUsageAndRefusalCost() async throws {
        let payload: [String: Any] = [
            "choices": [["message": ["role": "assistant", "refusal": "Declined"]]],
            "usage": ["prompt_tokens": 10_000, "completion_tokens": 2_000, "total_tokens": 12_000]
        ]
        let fixture = OpenAINetworkFixture(data: try JSONSerialization.data(withJSONObject: payload))
        defer { fixture.cleanUp() }
        let transcript = Transcript()
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 1, text: "Sample")]
        let provider = OpenAILLMProvider(credentials: MockCredentialStore(key: "fixture-key"), client: OpenAILLMClient(session: fixture.session))
        let record = generation(recording())
        let tracker = OperationUsageTracker(generation: record)
        do {
            _ = try await UsageTrackingLLMProvider(base: provider, tracker: tracker).generateSummary(transcript: transcript, configuration: SummaryConfiguration())
            Issue.record("Expected refusal")
        } catch let error as LLMError { #expect(error == .refusal(message: "Declined")) }
        #expect(record.requests.first?.succeeded == false)
        #expect(record.usageCost.amount?.amount == Decimal(string: "0.0027"))
    }

    @Test func streamingHTTPUsageReachesCompletedResponse() async throws {
        let delta: [String: Any] = ["choices": [["delta": ["content": #"{"answer":"A reply","referenceSegmentIDs":[]}"#]]]]
        let usage: [String: Any] = ["choices": [], "usage": ["prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120]]
        let payload = [delta, usage].map { "data: " + String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! + "\n\n" }.joined() + "data: [DONE]\n\n"
        let fixture = OpenAINetworkFixture(data: Data(payload.utf8)); defer { fixture.cleanUp() }
        let client = OpenAILLMClient(session: fixture.session)
        let stream = try await client.streamChat(prompt: FormattedChatPrompt(systemInstructions: "System", messages: []),
            model: "gpt-4o-mini", apiKey: "fixture-key", segments: [])
        var result: LLMChatResponse?
        for try await event in stream {
            if case .completed(let response) = event { result = response }
        }
        #expect(result?.usage?.inputTokens == 100)
        #expect(result?.usage?.outputTokens == 20)
        #expect(result?.modelID == "gpt-4o-mini")
        let body = try OpenAILLMRequestDTO.encodeChatPayload(model: "gpt-4o-mini", messages: [], stream: true)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((object["stream_options"] as? [String: Bool])?["include_usage"] == true)
    }


    @Test func recordingWorkflowPersistsTranscriptionSummaryHistoryFiveChatsAndTotals() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        var recordingID: UUID?
        do {
            let container = try workspace.storage.makeContainer()
            let context = ModelContext(container)
            let recording = try await workspace.makeRecording(in: context)
            recordingID = recording.id
            let transcription = RecordingViewModel(recording: recording, provider: UsageFixtureTranscriptionProvider(), storage: workspace.storage)
            #expect(transcription.transcriptionEstimate.cost.status == .estimated)
            await transcription.startTranscription(using: SwiftDataTranscriptRepository(context: context))?.value
            #expect(recording.transcript != nil)
            let provider = UsageFixtureProvider()
            let resolver = FixedLLMProviderResolver(provider: provider)
            let summary = SummaryViewModel(recording: recording, resolver: resolver)
            let summaries = SwiftDataSummaryRepository(context: context)
            await summary.generateSummary(using: summaries)?.value
            await summary.generateSummary(using: summaries)?.value
            #expect(recording.summaryHistory.count == 1)
            #expect(recording.summary?.generationID != recording.summaryHistory.first?.generationID)
            let chat = ChatViewModel(recording: recording, resolver: resolver)
            chat.attachStorage(SwiftDataChatRepository(context: context))
            for index in 0..<5 {
                chat.inputText = "Question \(index)"
                chat.sendMessage()
                for _ in 0..<100 where chat.isGenerating { try await Task.sleep(for: .milliseconds(5)) }
                #expect(chat.generationState == .completed)
            }
            #expect(chat.session?.messages.filter { $0.role == .assistant }.count == 5)
            #expect(chat.session?.messages.filter { $0.role == .assistant }.allSatisfy { $0.generationID != nil } == true)
            try context.save()
        }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<GenerationRecord>())
        #expect(records.count == 8)
        let totals = UsageRepository().snapshot(records: records)
        #expect(totals.byFeature["summary"]?.knownAPIAmount == Decimal(string: "0.0054"))
        #expect(totals.byFeature["chat"]?.knownAPIAmount == Decimal(string: "0.0135"))
        #expect(totals.byFeature["transcription"]?.knownAPIAmount == Decimal(string: "0.0001"))
        #expect(totals.total.knownAPIAmount == Decimal(string: "0.019"))
        #expect(totals.byRecording[try #require(recordingID)] == totals.total)
        #expect(totals.total.completedResponses == 5)
        #expect(records.allSatisfy { $0.usageCost.status == .calculated })
    }


    @Test func effectiveDatesSelectJuneRateAndKeepItAfterAugustUpdate() throws {
        let june = try #require(ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z"))
        let august = try #require(ISO8601DateFormatter().date(from: "2026-08-15T00:00:00Z"))
        var first = try #require(ProviderPricingCatalog.bundled.snapshot(provider: "openAI", model: "gpt-4o-mini", operation: .summary, at: .now))
        first.effectiveFrom = june
        var second = first
        second.effectiveFrom = august
        second.inputTokenPrice = 1
        let catalog = ProviderPricingCatalog(definitions: [first, second])
        let record = generation(recording())
        record.startedAt = june
        let tracker = OperationUsageTracker(generation: record, catalog: catalog)
        tracker.finishRequest(tracker.beginRequest(at: june), usage: GenerationUsage(inputTokens: 10_000, outputTokens: 2_000), succeeded: true)
        #expect(record.usageCost.amount?.amount == Decimal(string: "0.0027"))
        #expect(catalog.snapshot(provider: "openAI", model: "gpt-4o-mini", operation: .summary, at: august)?.inputTokenPrice == 1)
        #expect(record.requests.first?.cost.pricingSnapshot == first)
        #expect(record.usageCost.amount?.amount == Decimal(string: "0.0027"))
    }

    @Test func unsupportedContextTierAndCacheWriteTTLStayUnavailable() throws {
        let pricing = try #require(ProviderPricingCatalog.bundled.snapshot(provider: "anthropic", model: "claude-sonnet-4-5", operation: .summary, at: .now))
        let usage = GenerationUsage(inputTokens: 100, outputTokens: 100, cachedInputTokens: 210_000, inputIncludesCachedTokens: false)
        #expect(CostCalculator().calculate(usage: usage, pricing: pricing, billing: .meteredAPI).status == .unknownPricing)
        var writes = GenerationUsage(inputTokens: 100, outputTokens: 100, cacheWriteInputTokens: 100, inputIncludesCachedTokens: false)
        #expect(CostCalculator().calculate(usage: writes, pricing: pricing, billing: .meteredAPI).status == .unavailable)
        writes.cacheWriteDurationSeconds = 300
        #expect(CostCalculator().calculate(usage: writes, pricing: pricing, billing: .meteredAPI).amount?.amount == Decimal(string: "0.002175"))
    }


    @Test func missingCredentialsDoNotInventProviderRequests() async throws {
        let record = generation(recording())
        let tracker = OperationUsageTracker(generation: record)
        let provider = OpenAILLMProvider(credentials: MockCredentialStore())
        await #expect(throws: LLMError.missingAPIKey) {
            _ = try await UsageTrackingLLMProvider(base: provider, tracker: tracker)
                .generateSummary(transcript: Transcript(), configuration: SummaryConfiguration())
        }
        #expect(record.requests.isEmpty)
        #expect(record.usageCost.amount == nil)
    }

    @Test func protocolAuthenticationSnapshotsActualMethod() {
        let provider: any LLMProvider = OpenAILLMProvider(credentials: MockCredentialStore())
        #expect(provider.authenticationMethod == .apiKey)
        let plan: any LLMProvider = ChatGPTPlanLLMProvider()
        #expect(plan.authenticationMethod == .chatGPTAccount)
    }
}

@MainActor
private final class UsageFixtureProvider: LLMProvider {
    var id: LLMProviderID { .openAI }
    var displayName: String { "Fixture" }
    var modelID: String? { "gpt-4o-mini" }
    var authenticationMethod: ProviderAuthenticationMethod? { .apiKey }
    func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
        let summary = Summary(overview: "Summary", modelName: "gpt-4o-mini")
        summary.reportedUsage = GenerationUsage(inputTokens: 10_000, outputTokens: 2_000)
        return summary
    }
    func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream {
            $0.yield(.completed(LLMChatResponse(content: "A reply", usage: GenerationUsage(inputTokens: 10_000, outputTokens: 2_000), modelID: modelID)))
            $0.finish()
        }
    }
}


@MainActor
private final class RetryingUsageFixtureProvider: LLMProvider {
    var id: LLMProviderID { .openAI }
    var displayName: String { "Fixture" }
    var modelID: String? { "gpt-4o-mini" }
    var authenticationMethod: ProviderAuthenticationMethod? { .apiKey }
    var calls = 0
    func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
        calls += 1
        let usage = GenerationUsage(inputTokens: 10_000, outputTokens: 2_000)
        if calls == 1 { throw ProviderUsageError(underlying: LLMError.rateLimited, usage: usage) }
        let summary = Summary(overview: "Summary", modelName: "gpt-4o-mini")
        summary.reportedUsage = usage
        return summary
    }
    func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}


@MainActor
private struct UsageFixtureTranscriptionProvider: TranscriptionProvider {
    var displayName: String { "OpenAI fixture" }
    var providerID: String? { "openAI" }
    var modelID: String? { "whisper-1" }
    var authenticationMethod: ProviderAuthenticationMethod? { .apiKey }
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        let transcript = Transcript()
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 1, text: "Meeting note.")]
        return transcript
    }
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress,
                    status: @escaping TranscriptionStatusReporter,
                    usage: @escaping @MainActor (TranscriptionRequestEvent) -> Void) async throws -> Transcript {
        let id = UUID(); usage(.began(id))
        let transcript = try await transcribe(audioURL: audioURL, progress: progress)
        usage(.finished(id, TranscriptionUsage(recordingDuration: 1, processedDuration: 1, providerReportedDuration: 1), true))
        return transcript
    }
}
