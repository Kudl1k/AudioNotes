import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct ProjectFoundationTests {
    @Test func navigationRestoresProjectsAndLegacyRecordingsAndFallsBackForDeletedIDs() {
        let projectID = UUID(), recordingID = UUID()
        let project = LibraryDestination.project(projectID)
        #expect(LibraryDestination(persistedValue: project.persistedValue) == project)
        #expect(project.available(recordingIDs: [recordingID], projectIDs: [projectID]) == project)
        #expect(project.available(recordingIDs: [recordingID], projectIDs: []) == .allRecordings)
        #expect(LibraryDestination(persistedValue: recordingID.uuidString) == .recording(recordingID))
        #expect(LibraryDestination(persistedValue: "invalid") == .allRecordings)
    }

    @Test func membershipAndRenamePreserveFilesAndEntireRecordingGraph() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let repository = SwiftDataProjectRepository(context: context, storage: workspace.storage)
        let a = try repository.create(name: " Operating Systems ", description: "  Notes  ")
        let b = try repository.create(name: "Machine Learning", description: nil)
        #expect(a.name == "Operating Systems")
        #expect(a.projectDescription == "Notes")
        #expect(throws: ProjectEditingError.self) { try repository.create(name: " ", description: nil) }
        let recording = try await workspace.makeRecording(in: context)
        recording.transcript = sampleTranscript()
        recording.summary = Summary(text: "Keep summary")
        let chat = ChatSession(); chat.messages = [ChatMessage(role: .assistant, text: "Keep chat")]
        recording.chatSessions = [chat]
        let source = RecordingSource(type: .document, displayName: "Private notes", originalFilename: "notes.md", localFileReference: "original.md", status: .ready)
        source.recording = recording
        source.textUnits = [try SourceTextUnit(position: 0, text: "private text", origin: .nativeText, locator: .document(section: "Notes", start: 0, end: 12))]
        context.insert(source)
        let generation = GenerationRecord(recording: recording, feature: .summary, provider: .openAI, model: "existing-model", presetName: "General", outputLength: .detailed, settings: nil)
        generation.usageCost = .init(amount: Money(amount: Decimal(string: "0.123456")!), billingKind: .meteredAPI, status: .calculated)
        context.insert(generation)
        try context.save()
        let file = workspace.storage.recordingURL(fileName: recording.audioFileName)
        let audio = try Data(contentsOf: file)
        let sourceDirectory = workspace.storage.sourceDirectory(id: source.id)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data("private text".utf8).write(to: workspace.storage.sourceURL(source))
        try repository.move(recording, to: a)
        #expect(a.recordings.map(\.id) == [recording.id])
        let id = a.id
        try repository.rename(a, name: "OSY", description: nil)
        #expect(a.id == id)
        try repository.move(recording, to: b)
        #expect(a.recordings.isEmpty)
        #expect(b.recordings.count == 1)
        try repository.move(recording, to: nil)
        #expect(b.recordings.isEmpty)
        #expect(recording.project == nil)
        try repository.move(recording, to: a)
        try repository.delete(a, deletingRecordings: false)
        #expect(recording.project == nil)
        #expect(try Data(contentsOf: file) == audio)
        #expect(try workspace.importedFiles().count == 1)
        #expect(FileManager.default.fileExists(atPath: sourceDirectory.path))
        #expect(recording.transcript?.segments.count == 1)
        #expect(recording.summary?.text == "Keep summary")
        #expect(recording.chatSessions.first?.messages.first?.text == "Keep chat")
        #expect(recording.sources.first?.id == source.id)
        #expect(recording.generationRecords.first?.usageCost.amount?.amount == Decimal(string: "0.123456"))
        try repository.delete(b, deletingRecordings: false)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 0)
    }

    @Test func projectSourceReopensWithStableChunksAndDeletesOnlyManagedFiles() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let original = workspace.root.appending(path: "notes.md")
        try "# Kernel\nDriver registration".write(to: original, atomically: true, encoding: .utf8)
        let projectID: UUID
        let sourceID: UUID
        var chunkIDs: [UUID] = []
        do {
            let container = try workspace.storage.makeContainer()
            let context = ModelContext(container)
            let project = try SwiftDataProjectRepository(context: context, storage: workspace.storage).create(name: "Documents", description: nil)
            projectID = project.id
            let queue = ProjectImportQueue(storage: workspace.storage)
            queue.enqueue([original], to: project, context: context)
            await queue.waitUntilIdle()
            let source = try #require(project.sources.first)
            sourceID = source.id
            #expect(source.recording == nil)
            #expect(source.project?.id == project.id)
            #expect(source.status == .ready)
            chunkIDs = sourceChunks(source).map(\.id)
            #expect(!chunkIDs.isEmpty)
            #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 0)
            #expect(try context.fetchCount(FetchDescriptor<GenerationRecord>()) == 0)
        }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        let repository = SwiftDataProjectRepository(context: context, storage: workspace.storage)
        let project = try #require(context.fetch(FetchDescriptor<Project>()).first)
        let source = try #require(project.sources.first)
        #expect(project.id == projectID)
        #expect(source.id == sourceID)
        #expect(sourceChunks(source).map(\.id) == chunkIDs)
        let url = workspace.storage.sourceURL(source)
        try repository.rename(project, name: "Renamed", description: "Documents only")
        #expect(workspace.storage.sourceURL(source) == url)
        try repository.renameSource(source, in: project, name: "Renamed notes")
        #expect(source.displayName == "Renamed notes" && workspace.storage.sourceURL(source) == url)
        try repository.deleteSource(source, from: project)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(project.sources.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<SourceTextUnit>()) == 0)
    }

    @Test func deletingMissingPrimaryAudioNeverRemovesOtherRecordingFiles() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let repository = SwiftDataProjectRepository(context: context, storage: workspace.storage)
        let retained = try await workspace.makeRecording(in: context)
        let retainedURL = workspace.storage.recordingURL(fileName: retained.audioFileName)
        let project = try repository.create(name: "Missing audio", description: nil)
        let missing = Recording(title: "Missing", audioFileName: "", originalFileName: "", duration: 0)
        missing.project = project
        let source = RecordingSource(type: .audio, displayName: "Missing primary", originalFilename: "", localFileReference: "")
        source.isPrimaryAudio = true
        missing.sources = [source]
        context.insert(missing)
        try context.save()
        try repository.delete(project, deletingRecordings: true)
        #expect(FileManager.default.fileExists(atPath: retainedURL.path))
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 1)
    }

    @Test func destructiveDeletionCascadesRecordingHistoryAndCleansBothScopes() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let repository = SwiftDataProjectRepository(context: context, storage: workspace.storage)
        let project = try repository.create(name: "Delete", description: nil)
        let recording = try await workspace.makeRecording(in: context)
        recording.transcript = sampleTranscript()
        try repository.move(recording, to: project)
        let document = workspace.root.appending(path: "notes.txt")
        try "Useful notes".write(to: document, atomically: true, encoding: .utf8)
        let queue = ProjectImportQueue(storage: workspace.storage)
        queue.enqueue([document], to: project, context: context)
        await queue.waitUntilIdle()
        let source = try #require(project.sources.first)
        let directory = workspace.storage.sourceDirectory(id: source.id)
        try repository.delete(project, deletingRecordings: true)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSegment>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RecordingSource>()) == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try workspace.importedFiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: document.path))
    }

    @Test func projectSourcesNeverEnterRecordingAIContext() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try multiSourceFixture()
        let project = Project(name: "Strict scope")
        context.insert(project)
        context.insert(recording)
        recording.project = project
        let source = RecordingSource(type: .document, displayName: "Shared", originalFilename: "shared.txt", localFileReference: "original.txt", status: .ready)
        source.textUnits = [try SourceTextUnit(position: 0, text: "Shared project secrets", origin: .nativeText, locator: .document(section: "Notes", start: 0, end: 22))]
        source.project = project
        context.insert(source)
        try context.save()
        #expect(!RecordingContextSnapshot(recording: recording).chunks.contains { $0.sourceID == source.id })
        #expect(!RecordingContextAvailability.readySourceIDs(recording).contains(source.id))
        #expect(!ExportContentBuilder.build(from: recording).sourceNames.contains("Shared"))
        #expect(!sourceChunks(source).isEmpty)
    }

    @Test func recordingMoveDoesNotCancelActiveTranscriptionOrSelection() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        let project = try SwiftDataProjectRepository(context: context).create(name: "Lectures", description: nil)
        let provider = SuspendedTranscriptionProvider()
        let library = LibraryViewModel()
        let model = library.transcriptionModel(for: recording, resolver: FixedTranscriptionProviderResolver(provider: provider), storage: workspace.storage)
        let task = try #require(model.startTranscription(using: SwiftDataTranscriptRepository(context: context)))
        await provider.waitForCalls(1)
        library.selectProject(project.id)
        try SwiftDataProjectRepository(context: context).move(recording, to: project)
        #expect(model.state == .transcribing)
        #expect(library.projectSelection == project.id)
        #expect(library.selection == nil)
        #expect(!library.canDelete(recording))
        provider.finishCall(0)
        await task.value
        #expect(model.state == .completed)
        #expect(recording.transcript?.segments.count == 1)
        #expect(library.projectSelection == project.id)
        library.selectRecording(recording.id)
        #expect(library.projectSelection == nil)
        #expect(library.selection == recording.id)
    }
}

@MainActor
func sourceChunks(_ source: RecordingSource) -> [SourceChunk] {
    RecordingContextSnapshot.chunks(for: .init(id: source.id, name: source.displayName, type: source.type,
        segments: [], units: source.textUnits.map { .init(id: $0.id, position: $0.position, text: $0.text, locator: $0.locator, origin: $0.origin) }))
}
