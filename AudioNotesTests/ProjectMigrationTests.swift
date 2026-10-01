import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct ProjectMigrationTests {
    @Test func preM12OnDiskStoreMigratesWithoutChangingSourcesHistoryOrPricing() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        try FileManager.default.createDirectory(at: workspace.storage.rootURL, withIntermediateDirectories: true)
        let recordingID = UUID(), sourceID = UUID(), segmentID = UUID(), unitID = UUID()
        let references = [SourceReference(sourceID: sourceID, chunkID: StableSourceID.make("\(sourceID)-\(unitID)-0"),
            sourceName: "Slides", sourceType: .pdf, locator: .pdf(pageIndex: 3), excerpt: "Existing text")]
        let referenceData = try JSONEncoder().encode(references)
        let pricing = try #require(ProviderPricingCatalog.bundled.snapshot(provider: LLMProviderID.openAI.rawValue, model: "gpt-4o-mini", operation: .summary, at: .now))
        let request = RequestUsageRecord(id: UUID(), startedAt: .now, modelID: "gpt-4o-mini",
            usage: GenerationUsage(inputTokens: 1000, outputTokens: 200, totalTokens: 1200),
            cost: CostCalculator().calculate(usage: GenerationUsage(inputTokens: 1000, outputTokens: 200, totalTokens: 1200),
                pricing: pricing, billing: .meteredAPI), succeeded: true)
        let usageData = try JSONEncoder().encode([request])
        let costData = try JSONEncoder().encode(UsageCost(amount: Money(amount: Decimal(string: "1.23456789")!), billingKind: .meteredAPI, status: .calculated))
        let generationID: UUID
        do {
            let schema = Schema([LegacyM11Schema.Recording.self, LegacyM11Schema.RecordingSource.self, LegacyM11Schema.SourceTextUnit.self,
                LegacyM11Schema.Transcript.self, LegacyM11Schema.TranscriptSegment.self, LegacyM11Schema.Summary.self,
                LegacyM11Schema.ChatSession.self, LegacyM11Schema.ChatMessage.self, LegacyM11Schema.AIPreset.self, LegacyM11Schema.GenerationRecord.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: workspace.storage.rootURL.appending(path: "Library.store"))])
            let context = ModelContext(container)
            let recording = LegacyM11Schema.Recording(id: recordingID, title: "Legacy lecture", audioFileName: "legacy.wav", originalFileName: "original.wav", duration: 3600)
            let transcript = LegacyM11Schema.Transcript(languageCode: "cs", sourceName: "Existing provider")
            transcript.segments = [LegacyM11Schema.TranscriptSegment(id: segmentID, position: 0, startTime: 51, endTime: 60, text: "Původní přepis")]
            recording.transcript = transcript
            recording.transcriptHistory = [LegacyM11Schema.Transcript(languageCode: "en")]
            let source = LegacyM11Schema.RecordingSource(id: sourceID, type: .pdf, displayName: "Slides", originalFilename: "slides.pdf", localFileReference: "original.pdf", status: .ready)
            source.contentHash = "existing-hash"
            source.textUnits = [try LegacyM11Schema.SourceTextUnit(id: unitID, position: 0, text: "Existing text", origin: .nativeText, locator: .pdf(pageIndex: 3))]
            recording.sources = [source]
            let summary = LegacyM11Schema.Summary(text: "Existing summary", outputLength: .detailed)
            summary.sourceReferencesData = referenceData
            recording.summary = summary
            recording.summaryHistory = [LegacyM11Schema.Summary(text: "Historical summary")]
            let session = LegacyM11Schema.ChatSession()
            let message = LegacyM11Schema.ChatMessage(role: .assistant, text: "Existing answer", references: [.init(segmentID: segmentID, startTime: 51)])
            message.sourceReferencesData = referenceData
            session.messages = [message]; recording.chatSessions = [session]
            let generation = LegacyM11Schema.GenerationRecord(recording: recording, feature: .summary, provider: .openAI, model: "historical-model", presetName: "General", outputLength: .detailed, settings: nil, authenticationMethod: .apiKey)
            generation.requestUsageData = usageData
            generation.costData = costData
            generation.executionLocationRaw = "cloud"
            recording.generationRecords = [generation]
            generationID = generation.id
            context.insert(recording)
            try context.save()
        }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        try SourceCompatibilityMigration().backfill(context: context)
        try SourceCompatibilityMigration().backfill(context: context)
        let recording = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(recording.id == recordingID && recording.project == nil)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 0)
        #expect(recording.audioFileName == "legacy.wav")
        #expect(recording.transcript?.segments.first?.id == segmentID)
        #expect(recording.transcript?.segments.first?.text == "Původní přepis")
        #expect(recording.transcriptHistory.count == 1)
        #expect(recording.summary?.text == "Existing summary")
        #expect(recording.summary?.outputLength == .detailed)
        #expect(recording.summary?.sourceReferencesData == referenceData)
        #expect(recording.summaryHistory.first?.text == "Historical summary")
        #expect(recording.chatSessions.first?.messages.first?.sourceReferencesData == referenceData)
        #expect(recording.chatSessions.first?.messages.first?.references.first?.segmentID == segmentID)
        let source = try #require(recording.sources.first { $0.id == sourceID })
        #expect(source.project == nil && source.recording?.id == recordingID)
        #expect(source.localFileReference == "original.pdf" && source.contentHash == "existing-hash")
        #expect(source.textUnits.first?.id == unitID)
        #expect(sourceChunks(source).first?.id == references.first?.chunkID)
        let generation = try #require(recording.generationRecords.first)
        #expect(generation.id == generationID)
        #expect(generation.requestUsageData == usageData)
        #expect(generation.costData == costData)
        #expect(generation.requests.first?.cost.pricingSnapshot == pricing)
        #expect(generation.requests.first?.usage?.inputTokens == 1000)
        #expect(generation.modelID == "historical-model")
        #expect(generation.authenticationMethodRaw == ProviderAuthenticationMethod.apiKey.rawValue)
        #expect(recording.sources.count == 2) // The existing idempotent primary-audio backfill.
    }

    @Test func interruptedProjectExtractionRecoversAfterReopen() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        do {
            let container = try workspace.storage.makeContainer()
            let context = ModelContext(container)
            let project = Project(name: "Interrupted")
            let source = RecordingSource(type: .pdf, displayName: "Slides", originalFilename: "slides.pdf", localFileReference: "original.pdf", status: .processing)
            project.sources = [source]
            context.insert(project)
            try context.save()
        }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        try SourceCompatibilityMigration().backfill(context: context)
        let project = try #require(context.fetch(FetchDescriptor<Project>()).first)
        #expect(project.sources.first?.status == .failed)
        #expect(project.sources.first?.processingError?.contains("interrupted") == true)
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 0)
    }
}
