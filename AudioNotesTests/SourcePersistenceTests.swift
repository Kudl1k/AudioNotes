import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct SourcePersistenceTests {
    @Test func preM9StoreMigratesWithoutLosingHistoryReferencesOrCost() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        try FileManager.default.createDirectory(at: workspace.storage.rootURL, withIntermediateDirectories: true)
        let recordingID = UUID()
        let segmentID = UUID()
        let generationID: UUID
        do {
            let schema = Schema([LegacyM8Schema.Recording.self, LegacyM8Schema.Transcript.self, LegacyM8Schema.TranscriptSegment.self,
                LegacyM8Schema.Summary.self, LegacyM8Schema.ChatSession.self, LegacyM8Schema.ChatMessage.self,
                LegacyM8Schema.AIPreset.self, LegacyM8Schema.GenerationRecord.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: workspace.storage.rootURL.appending(path: "Library.store"))])
            let context = ModelContext(container)
            let recording = LegacyM8Schema.Recording(id: recordingID, title: "Legacy lecture", audioFileName: "owned.m4a", originalFileName: "lecture.m4a", duration: 300)
            let transcript = LegacyM8Schema.Transcript(languageCode: "cs")
            transcript.segments = [LegacyM8Schema.TranscriptSegment(id: segmentID, position: 0, startTime: 20, endTime: 30, text: "České poznámky")]
            recording.transcript = transcript
            recording.summary = LegacyM8Schema.Summary(text: "Current summary")
            recording.summaryHistory = [LegacyM8Schema.Summary(text: "Previous summary")]
            let session = LegacyM8Schema.ChatSession()
            session.messages = [LegacyM8Schema.ChatMessage(role: .assistant, text: "Historical answer", references: [.init(segmentID: segmentID, startTime: 20)])]
            recording.chatSessions = [session]
            let generation = LegacyM8Schema.GenerationRecord(recording: recording, feature: .summary, provider: .openAI, model: "gpt-4o-mini", presetName: "General", outputLength: .detailed, settings: nil)
            generation.costData = try JSONEncoder().encode(UsageCost(amount: Money(amount: Decimal(string: "0.001234")!), billingKind: .meteredAPI, status: .calculated))
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
        #expect(recording.id == recordingID)
        #expect(recording.audioFileName == "owned.m4a")
        #expect(recording.sources.count == 1)
        #expect(recording.sources.first?.id == recordingID)
        #expect(recording.sources.first?.isPrimaryAudio == true)
        #expect(recording.transcript?.segments.first?.id == segmentID)
        #expect(recording.transcript?.segments.first?.text == "České poznámky")
        #expect(recording.summary?.text == "Current summary")
        #expect(recording.summaryHistory.first?.text == "Previous summary")
        #expect(recording.chatSessions.first?.messages.first?.references.first?.segmentID == segmentID)
        #expect(recording.generationRecords.first?.id == generationID)
        let cost = try #require(recording.generationRecords.first?.costData)
        #expect(try JSONDecoder().decode(UsageCost.self, from: cost).amount?.amount == Decimal(string: "0.001234"))
    }

    @Test func sourcesTextAndReferencesSurviveReopenAndCascade() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        var expectedIDs: [UUID] = []
        do {
            let container = try workspace.storage.makeContainer()
            let context = ModelContext(container)
            let recording = try multiSourceFixture()
            let chunks = RecordingContextSnapshot(recording: recording).chunks
            expectedIDs = chunks.map(\.id)
            let refs = SourceReferenceResolver().resolve(chunkIDs: expectedIDs.map(\.uuidString), against: chunks)
            let message = ChatMessage(role: .assistant, text: "Source-backed answer")
            message.sourceReferences = refs
            let session = ChatSession(); session.messages = [message]; recording.chatSessions = [session]
            let summary = Summary(text: "Multi-source summary"); summary.sourceReferences = refs; recording.summary = summary
            context.insert(recording); try context.save()
        }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        let recording = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(recording.sources.count == 4)
        #expect(RecordingContextSnapshot(recording: recording).chunks.map(\.id) == expectedIDs)
        #expect(SourceReferenceResolver().validate(recording.summary!.sourceReferences, recording: recording).count == expectedIDs.count)
        #expect(recording.chatSessions.first?.messages.first?.sourceReferences.count == expectedIDs.count)
        context.delete(recording); try context.save()
        #expect(try context.fetchCount(FetchDescriptor<RecordingSource>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SourceTextUnit>()) == 0)
    }

    @Test func removalDeletesOwnedFileAndDerivedReferencesButKeepsWorkspaceAndCost() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        let recording = try multiSourceFixture()
        context.insert(recording)
        let source = try #require(recording.sources.first { $0.type == .pdf })
        let directory = workspace.storage.sourceDirectory(id: source.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("owned file".utf8).write(to: workspace.storage.sourceURL(source))
        let chunks = RecordingContextSnapshot(recording: recording).chunks.filter { $0.sourceID == source.id }
        let refs = SourceReferenceResolver().resolve(chunkIDs: chunks.map { $0.id.uuidString }, against: chunks)
        let summary = Summary(text: "Retained answer"); summary.sourceReferences = refs; recording.summary = summary
        let message = ChatMessage(role: .assistant, text: "Retained chat"); message.sourceReferences = refs
        let session = ChatSession(); session.messages = [message]; recording.chatSessions = [session]
        let generation = GenerationRecord(recording: recording, feature: .chat, provider: .mock, model: nil, presetName: nil, outputLength: .medium, settings: nil)
        recording.generationRecords = [generation]
        try context.save()
        SourcesViewModel(recording: recording, storage: workspace.storage).remove(source, context: context)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(recording.sources.count == 3)
        #expect(recording.summary?.text == "Retained answer")
        #expect(recording.summary?.sourceReferences.isEmpty == true)
        #expect(message.sourceReferences.isEmpty)
        #expect(recording.generationRecords.count == 1)
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 1)
    }
}
