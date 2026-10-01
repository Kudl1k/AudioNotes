import Foundation
import SwiftData

struct UsageTotals: Equatable, Sendable {
    var operationCount = 0
    var completedResponses = 0
    var knownAPIAmount: Decimal = 0
    var unavailableRequests = 0
    var meteredRequests = 0
    var planRequests = 0
    var localRequests = 0

    var displayText: String {
        if operationCount == 0 { return "No tracked usage" }
        if meteredRequests == 0 { return "No metered API usage" }
        if meteredRequests > 0 && unavailableRequests == meteredRequests { return "Cost unavailable" }
        let value = MoneyFormatter.string(Money(amount: knownAPIAmount))
        return unavailableRequests > 0 ? "\(value) known · \(unavailableRequests) unavailable" : value
    }
}

struct UsageDashboardSnapshot: Sendable {
    var total = UsageTotals()
    var byFeature: [String: UsageTotals] = [:]
    var byProvider: [String: UsageTotals] = [:]
    var byProject: [UUID: UsageTotals] = [:]
    var byRecording: [UUID: UsageTotals] = [:]
}

enum UsageTimeRange: String, CaseIterable, Identifiable {
    case today = "Today", week = "This Week", month = "This Month", all = "All Time"
    var id: Self { self }
    func interval(now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .today: calendar.dateInterval(of: .day, for: now)
        case .week: calendar.dateInterval(of: .weekOfYear, for: now)
        case .month: calendar.dateInterval(of: .month, for: now)
        case .all: nil
        }
    }
}

/// Aggregates operation records, never traversing message or summary graphs from a view body.
@MainActor
struct UsageRepository {
    func markInterruptedOperations(context: ModelContext) throws {
        let unfinished = try context.fetch(FetchDescriptor<GenerationRecord>(predicate: #Predicate { $0.statusRaw == "inProgress" }))
        for record in unfinished {
            record.statusRaw = GenerationStatus.cancelled.rawValue
            record.updateCost()
        }
        if !unfinished.isEmpty { try context.save() }
    }

    func snapshot(records: [GenerationRecord], interval: DateInterval? = nil) -> UsageDashboardSnapshot {
        var result = UsageDashboardSnapshot()
        for record in records {
            let requests = record.requests.filter { request in
                interval.map { request.startedAt >= $0.start && request.startedAt < $0.end } ?? true
            }
            if requests.isEmpty {
                if !record.requests.isEmpty { continue }
                if let interval, !(record.startedAt >= interval.start && record.startedAt < interval.end) { continue }
            }
            let totals = Self.totals(record, requests: requests)
            Self.add(totals, to: &result.total)
            Self.add(totals, to: &result.byFeature[record.featureRaw, default: UsageTotals()])
            Self.add(totals, to: &result.byProvider[record.providerIDRaw ?? "Unknown", default: UsageTotals()])
            if let id = record.recordingID { Self.add(totals, to: &result.byRecording[id, default: UsageTotals()]) }
            if let id = record.projectID { Self.add(totals, to: &result.byProject[id, default: UsageTotals()]) }
        }
        return result
    }

    private static func totals(_ record: GenerationRecord, requests: [RequestUsageRecord]) -> UsageTotals {
        var result = UsageTotals()
        result.operationCount = 1
        result.completedResponses = record.featureRaw == "chat" && record.statusRaw == "succeeded" ? 1 : 0
        // Include known successful requests even when another request in the job is unknown.
        let costs = requests.map(\.cost)
        let entries = costs.isEmpty ? [record.usageCost] : costs
        for cost in entries {
            switch cost.billingKind {
            case .meteredAPI:
                result.meteredRequests += 1
                if let amount = cost.amount, amount.currency == .usd { result.knownAPIAmount += amount.amount }
                else { result.unavailableRequests += 1 }
            case .subscription: if !costs.isEmpty { result.planRequests += 1 }
            case .local: result.localRequests += 1
            case .unknown:
                result.meteredRequests += 1
                result.unavailableRequests += 1
            }
        }
        return result
    }

    private static func add(_ value: UsageTotals, to total: inout UsageTotals) {
        total.operationCount += value.operationCount
        total.completedResponses += value.completedResponses
        total.knownAPIAmount += value.knownAPIAmount
        total.unavailableRequests += value.unavailableRequests
        total.meteredRequests += value.meteredRequests
        total.planRequests += value.planRequests
        total.localRequests += value.localRequests
    }
}

extension GenerationRecord {
    var providerDisplayName: String {
        providerIDRaw.flatMap(LLMProviderID.init(rawValue:))?.title
            ?? providerIDRaw.flatMap(TranscriptionProviderID.init(rawValue:))?.title ?? "Unknown provider"
    }
    var usageDetails: String {
        let provider = providerDisplayName
        let auth = authenticationMethodRaw.flatMap(ProviderAuthenticationMethod.init(rawValue:))
        let path = auth == .chatGPTAccount ? "ChatGPT plan" : auth == .claudeCode ? "Claude Code login" : auth == .apiKey ? "API key" : auth?.rawValue ?? "Unknown authentication"
        var parts = [provider, modelDisplayNameSnapshot ?? modelID ?? "Unknown model", usageCost.displayText]
        if let location = executionLocationRaw.flatMap(ProviderExecutionLocation.init(rawValue:)) { parts.append(location.title) }
        if authenticationMethodRaw != nil { parts.append(path) }
        parts.append("Processing time: " + AudioTime.string(durationSeconds))
        if billingKind == .local, let recording, featureRaw == "transcription", durationSeconds > 0 {
            parts.append(String(format: "%.1f× realtime", recording.duration / durationSeconds))
        }
        let timing = requests.compactMap { $0.usage?.providerSpecificUsage?["eval_duration_ns"] }.reduce(0, +)
        if timing > 0, let outputTokens { parts.append(String(format: "%.1f tokens/s", Double(outputTokens) / (Double(timing) / 1e9))) }
        if let count = retrievedSourceCount { parts.append("Retrieved \(chunkCount) chunks from \(count) sources") }
        if let tokens = estimatedHistoryTokens { parts.append("History: ~\(tokens) tokens (estimate)") }
        if let tokens = estimatedProjectContextTokens { parts.append("Project context: ~\(tokens) tokens (estimate)") }
        if imageInputCount > 0 { parts.append("\(imageInputCount) image inputs") }
        if let inputTokens { parts.append("\(inputTokens) input tokens") }
        if let outputTokens { parts.append("\(outputTokens) output tokens") }
        parts.append("\(requests.count) requests · \(attemptCount) attempts · \(statusRaw)")
        if featureRaw == "transcription", let recording { parts.append("Recording: \(AudioTime.string(recording.duration))") }
        if let estimate = estimatedCostData.flatMap({ try? JSONDecoder().decode(UsageCost.self, from: $0) }) {
            parts.append("Before generation: " + estimate.displayText)
        }
        if let estimate = estimatedCostRangeData.flatMap({ try? JSONDecoder().decode(EstimatedCostRange.self, from: $0) }) {
            parts.append("Before generation: " + estimate.displayText)
        }
        let durations = requests.compactMap(\.transcriptionUsage)
        if !durations.isEmpty {
            let processed = durations.compactMap { $0.providerReportedDuration ?? $0.processedDuration }.reduce(Decimal.zero, +)
            parts.append("Provider processed: \(processed) seconds")
        }
        return parts.joined(separator: " · ")
    }
}
