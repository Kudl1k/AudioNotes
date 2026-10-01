import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct V1MigrationFixtureTests {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/v1/library.sqlite")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUDIONOTES_WRITE_V1_FIXTURE"] != "1"))
    func publishedV1FixtureReopensWithoutLosingHistories() throws {
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            Issue.record("The archived v1 migration fixture is missing."); return
        }
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        try FileManager.default.createDirectory(at: workspace.storage.rootURL, withIntermediateDirectories: true)
        let database = workspace.storage.rootURL.appending(path: "Library.store")
        try FileManager.default.copyItem(at: fixture, to: database)
        let context = ModelContext(try workspace.storage.makeContainer())
        let projects = try context.fetch(FetchDescriptor<Project>())
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        #expect(projects.count == 1)
        #expect(recordings.count == 2)
        let project = try #require(projects.first)
        let recording = try #require(recordings.first { $0.project != nil })
        #expect(project.name == "V1 český projekt")
        #expect(recording.title == "V1 synthetic recording")
        #expect(recording.transcript?.orderedSegments.first?.text == "Příliš žluťoučký kůň")
        #expect(recording.summaryHistory.first?.text == "Previous summary")
        #expect(recording.transcriptHistory.count == 1)
        #expect(recording.chatSessions.first?.messages.count == 2)
        #expect(project.chatSessions.first?.messages.first?.text == "Project answer")
        #expect(project.sources.first?.textUnits.first?.text == "Synthetic shared document")
        #expect(try context.fetchCount(FetchDescriptor<AIPreset>()) == 1)
        #expect(recording.generationRecords.first?.usageCost.amount?.amount == Decimal(string: "0.001234"))
        #expect(project.generationRecords.first?.projectID == project.id)
        #expect(recordings.contains { $0.project == nil })
        #expect(FileManager.default.fileExists(atPath: workspace.storage.rootURL.appending(path: "Backups/pre-v1.store").path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUDIONOTES_WRITE_V1_FIXTURE"] == "1"))
    func writeBaselineOnlyWhenExplicitlyRequested() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        let project = Project(id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!, name: "V1 český projekt")
        let recording = Recording(title: "V1 synthetic recording", audioFileName: "synthetic.wav", originalFileName: "synthetic.wav", duration: 60)
        let transcript = Transcript(languageCode: "cs")
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Příliš žluťoučký kůň", speaker: "Speaker 1")]
        recording.transcript = transcript
        let old = Transcript(languageCode: "en"); old.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Previous transcript")]
        recording.transcriptHistory = [old]
        recording.summary = Summary(text: "Current summary")
        recording.summaryHistory = [Summary(text: "Previous summary")]
        let chat = ChatSession(); chat.messages = [ChatMessage(role: .user, text: "Question"), ChatMessage(role: .assistant, text: "Answer", references: [.init(segmentID: transcript.segments[0].id, startTime: 0)])]
        recording.chatSessions = [chat]
        let source = RecordingSource(type: .document, displayName: "Shared document", originalFilename: "synthetic.md", localFileReference: "original.md", status: .ready)
        source.textUnits = [try SourceTextUnit(position: 0, text: "Synthetic shared document", origin: .nativeText, locator: .document(section: "Introduction", start: 0, end: 25))]
        project.sources = [source]; project.recordings = [recording]
        let projectChat = ChatSession(); projectChat.messages = [ChatMessage(role: .assistant, text: "Project answer")]; project.chatSessions = [projectChat]
        let usage = GenerationRecord(recording: recording, feature: .summary, provider: .openAI, model: "gpt-4o-mini", presetName: "General", outputLength: .detailed, settings: nil)
        usage.costData = try JSONEncoder().encode(UsageCost(amount: Money(amount: Decimal(string: "0.001234")!), billingKind: .meteredAPI, status: .calculated))
        recording.generationRecords = [usage]
        project.generationRecords = [GenerationRecord(feature: .chat, provider: .ollama, model: "synthetic", presetName: nil, outputLength: .medium, settings: nil, billingKind: .local, project: project)]
        context.insert(project)
        context.insert(Recording(title: "Standalone", audioFileName: "standalone.wav", originalFileName: "standalone.wav", duration: 5))
        context.insert(AIPreset(name: "V1 fixture preset", feature: .summary, basePreset: .general))
        try context.save()
        let destination = workspace.storage.rootURL.appending(path: "fixture.sqlite")
        try MetadataBackup().snapshot(database: workspace.storage.rootURL.appending(path: "Library.store"), destination: destination)
        let archive = URL(fileURLWithPath: "/tmp/AudioNotes-M13-V1-Fixture/library.sqlite")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
        try FileManager.default.copyItem(at: destination, to: archive)
    }
}
