import SwiftData
import SwiftUI

struct UsageCostView: View {
    var recordingID: UUID? = nil
    var projectID: UUID? = nil
    var feature: GenerationFeature? = nil
    var isEmbedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \GenerationRecord.startedAt, order: .reverse) private var records: [GenerationRecord]
    @State private var range: UsageTimeRange = .month
    @State private var snapshot = UsageDashboardSnapshot()
    @State private var visibleRecords: [GenerationRecord] = []

    var body: some View {
        presentation
        .task(id: records.map { "\($0.id)-\($0.requestUsageData?.hashValue ?? 0)-\($0.statusRaw)" }.joined() + range.rawValue) {
            let scoped = records.filter { (recordingID == nil || $0.recordingID == recordingID) && (projectID == nil || $0.projectID == projectID) && (feature == nil || $0.featureRaw == feature?.rawValue) }
            let interval = range.interval()
            snapshot = UsageRepository().snapshot(records: scoped, interval: interval)
            visibleRecords = scoped.filter { record in
                interval.map { interval in
                    record.requests.isEmpty ? record.startedAt >= interval.start && record.startedAt < interval.end
                        : record.requests.contains { $0.startedAt >= interval.start && $0.startedAt < interval.end }
                } ?? true
            }
        }
        .onAppear { if recordingID != nil || projectID != nil { range = .all } }
    }

    private var periodPicker: some View {
        Picker("Time range", selection: $range) {
            ForEach(UsageTimeRange.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    private var usageForm: some View {
        Form {
            Section("Period") {
                periodPicker
            }
            Section("API Costs") {
                LabeledContent("Total in USD", value: snapshot.total.displayText)
            }
            if !snapshot.byFeature.isEmpty {
                Section("By Activity") { featureRows }
            }
            if !snapshot.byProvider.isEmpty {
                Section("By Provider") { providerRows }
            }
            Section {
                ForEach(AccountUsageProvider.allCases, id: \.self) { provider in
                    let usage = snapshot.byAccountProvider[provider, default: AccountRequestUsage()]
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(provider.title, value: "\(usage.requestCount) requests")
                        if usage.requestsWithTokenCount > 0 {
                            Text("\(usage.reportedTokens.formatted()) reported tokens")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if usage.requestsWithTokenCount < usage.requestCount {
                            let missing = usage.requestCount - usage.requestsWithTokenCount
                            Text("Token count unavailable for \(missing) requests")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Account Usage")
            } footer: {
                Text("Requests recorded by Soniquill in the selected period.")
            }
            Section("History") {
                if visibleRecords.isEmpty {
                    Text("No operations in this period").foregroundStyle(.secondary)
                } else {
                    history(title: "Operations")
                }
            }
            Section {
                DisclosureGroup("Provider Limits & Pricing") {
                    ForEach(AccountUsageProvider.allCases, id: \.self) { provider in
                        Link(provider.dashboardTitle, destination: provider.dashboardURL)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    pricingLinks
                    pricingDate
                    pricingExplanation
                }
            }
        }
        .navigationTitle("Usage & Costs")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#else
        .formStyle(.grouped)
        .disclosureGroupStyle(FullWidthDisclosureStyle())
#endif
    }

    @ViewBuilder
    private var presentation: some View {
#if os(iOS)
        if isEmbedded {
            usageForm
        } else {
            NavigationStack {
                usageForm
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
        }
#else
        if isEmbedded {
            usageForm
        } else {
            macDashboard
        }
#endif
    }

#if os(macOS)
    private var macDashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Usage & Cost").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            periodPicker.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("ChatGPT & Gemini") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Requests recorded by Soniquill in the selected period.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(AccountUsageProvider.allCases, id: \.self) { provider in
                                let usage = snapshot.byAccountProvider[provider, default: AccountRequestUsage()]
                                VStack(alignment: .leading, spacing: 5) {
                                    LabeledContent(provider.title, value: usage.requestCount == 0
                                        ? "No tracked requests" : usage.requestCount.formatted() + " requests")
                                    tokenRows(usage)
                                    Link(provider.dashboardTitle, destination: provider.dashboardURL).font(.callout)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("Metered API usage · USD") {
                        VStack(alignment: .leading, spacing: 8) { costRows }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    GroupBox("By provider") {
                        VStack(alignment: .leading, spacing: 8) { providerRows }.padding(6)
                    }
                    pricingExplanation
                    history(title: "Operation history")
                    pricingDate
                    HStack { pricingLinks }.font(.caption)
                }
            }
        }
        .padding(24).frame(minWidth: 600, idealWidth: 680, minHeight: 500)
    }
#endif

    @ViewBuilder
    private func tokenRows(_ usage: AccountRequestUsage) -> some View {
        if usage.requestsWithTokenCount > 0 {
            LabeledContent("Reported tokens", value: usage.reportedTokens.formatted())
        }
        if usage.requestsWithTokenCount < usage.requestCount {
            let unreported = usage.requestCount - usage.requestsWithTokenCount
            Text("Token usage unavailable for \(unreported) requests")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var costRows: some View {
        Group {
            Text(snapshot.total.displayText).font(.title2)
            if let chat = snapshot.byFeature["chat"], chat.completedResponses > 0 {
                Text("\(chat.completedResponses) AI responses").font(.caption).foregroundStyle(.secondary)
            }
            featureRows
        }
    }

    private var featureRows: some View {
        ForEach(snapshot.byFeature.keys.sorted(), id: \.self) { feature in
            LabeledContent(feature.capitalized, value: snapshot.byFeature[feature]?.displayText ?? "Cost unavailable")
        }
    }

    private var providerRows: some View {
        ForEach(snapshot.byProvider.keys.sorted(), id: \.self) { provider in
            LabeledContent(LLMProviderID(rawValue: provider)?.title ?? TranscriptionProviderID(rawValue: provider)?.title ?? "Unknown provider",
                           value: snapshot.byProvider[provider]?.displayText ?? "Cost unavailable")
        }
    }

    private func history(title: LocalizedStringKey) -> some View {
        DisclosureGroup(title) {
            ForEach(visibleRecords) { record in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(record.featureRaw.capitalized) · \(record.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    Text(record.usageDetails).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
        }
    }

    private var pricingExplanation: some View {
        Text("Calculated costs use bundled standard API rates. Provider invoices may differ due to account tiers, discounts, taxes or billing precision.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var pricingDate: some View {
        Text("Pricing verified September 30, 2026 · Display currency USD")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var pricingLinks: some View {
        Group {
            Link("OpenAI pricing", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
            Link("Claude pricing", destination: URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!)
            Link("Gemini pricing", destination: URL(string: "https://ai.google.dev/gemini-api/docs/pricing")!)
        }
    }
}

/// A generation lookup uses the operation table, independent of message/history relationships.
struct GenerationCostLabel: View {
    let generationID: UUID?
    var details = false
    @Query private var records: [GenerationRecord]
    init(generationID: UUID?, details: Bool = false) {
        self.generationID = generationID
        self.details = details
        let lookupID = generationID ?? UUID()
        _records = Query(filter: #Predicate<GenerationRecord> { $0.id == lookupID })
    }
    var body: some View {
        if let record = records.first {
            Text(details ? record.usageDetails : record.usageCost.displayText)
                .font(.caption).foregroundStyle(.secondary).help(record.usageDetails)
        } else {
            Text("Cost unavailable").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct GenerationDetailsButton: View {
    let generationID: UUID?
    @State private var showsDetails = false
    var body: some View {
        Button("Generation details", systemImage: "info.circle") { showsDetails.toggle() }
            .labelStyle(.iconOnly).buttonStyle(.borderless).font(.caption)
            .popover(isPresented: $showsDetails) {
                GenerationCostLabel(generationID: generationID, details: true)
                    .textSelection(.enabled).padding().frame(width: 340)
            }
    }
}

struct TranscriptionCostLabel: View {
    @Query private var records: [GenerationRecord]
    init(recordingID: UUID) {
        _records = Query(filter: #Predicate<GenerationRecord> {
            $0.recordingID == recordingID && $0.featureRaw == "transcription" && $0.statusRaw == "succeeded"
        }, sort: \GenerationRecord.startedAt, order: .reverse)
    }
    var body: some View {
        if let record = records.first {
            Text("\(record.providerDisplayName) · \(record.usageCost.displayText)")
                .font(.caption).foregroundStyle(.secondary).help(record.usageDetails)
        }
    }
}

struct TranscriptionCostInlineLabel: View {
    @Query private var records: [GenerationRecord]
    init(recordingID: UUID) {
        _records = Query(filter: #Predicate<GenerationRecord> {
            $0.recordingID == recordingID && $0.featureRaw == "transcription" && $0.statusRaw == "succeeded"
        }, sort: \GenerationRecord.startedAt, order: .reverse)
    }
    var body: some View {
        if let record = records.first {
            Text("·").accessibilityHidden(true)
            Text("\(record.providerDisplayName) · \(record.usageCost.displayText)")
                .lineLimit(1)
                .truncationMode(.tail)
                .help(record.usageDetails)
        }
    }
}
