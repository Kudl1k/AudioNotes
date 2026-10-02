import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct LibraryViewModelTests {
    @Test func batchContinuesAfterInvalidFileAndSelectsSavedRecording() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let valid = try workspace.makeAudio()
        let invalid = workspace.root.appending(path: "invalid.wav")
        try Data("invalid".utf8).write(to: invalid)
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let model = LibraryViewModel(importer: AudioImportService(storage: workspace.storage))
        await model.importURLs([invalid, valid], into: SwiftDataRecordingRepository(context: context))
        let recording = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(model.selection == recording.id)
        #expect(model.error?.kind == .importFailed && model.error?.message.contains("invalid.wav") == true)
        #expect(!model.isImporting)
        #expect(try workspace.importedFiles().count == 1)
        let importedFile = try workspace.importedFiles().first
        #expect(recording.audioFileName == importedFile?.lastPathComponent)
    }

    @Test func persistenceFailureRemovesCopiedAudio() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let model = LibraryViewModel(importer: AudioImportService(storage: workspace.storage))
        await model.importURLs([try workspace.makeAudio()], into: FailingRepository())
        #expect(try workspace.importedFiles().isEmpty)
        #expect(model.selection == nil)
        #expect(model.error?.kind == .importFailed)
        #expect(!model.isImporting)
    }

    @Test func transcriptionModelIsRetainedAcrossRecordingNavigation() {
        let model = LibraryViewModel()
        let recording = Recording(title: "Working", audioFileName: "audio.wav", originalFileName: "audio.wav", duration: 600)
        let resolver = FixedTranscriptionProviderResolver(provider: MockTranscriptionProvider())
        let first = model.transcriptionModel(for: recording, resolver: resolver)
        #expect(first.state == .idle)
        #expect(model.transcriptionModel(for: recording, resolver: resolver) === first)
    }

    @Test func renameTrimsNameRejectsBlankAndPersists() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        let recording = Recording(title: "Original", audioFileName: "", originalFileName: "", duration: 0)
        context.insert(recording)
        try context.save()
        let model = LibraryViewModel()
        let repository = SwiftDataRecordingRepository(context: context, storage: workspace.storage)
        model.rename(recording, to: " \n ", using: repository)
        #expect(recording.title == "Original")
        model.rename(recording, to: "  Meeting notes\n", using: repository)
        let reopened = ModelContext(try workspace.storage.makeContainer())
        #expect(try reopened.fetch(FetchDescriptor<Recording>()).first?.title == "Meeting notes")
    }

    @Test func revealFindsManagedSourcesDeduplicatesPrimaryAudioAndSkipsMissingFiles() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let model = LibraryViewModel(importer: AudioImportService(storage: workspace.storage))
        await model.importURLs([try workspace.makeAudio()], into: SwiftDataRecordingRepository(context: context, storage: workspace.storage))
        let recording = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        let audio = workspace.storage.recordingURL(fileName: recording.audioFileName)
        #expect(model.revealURLs(for: recording, storage: workspace.storage) == [audio])
        let source = RecordingSource(type: .document, displayName: "Notes", originalFilename: "notes.txt", localFileReference: "notes.txt")
        recording.sources.append(source)
        try FileManager.default.createDirectory(at: workspace.storage.sourceDirectory(id: source.id), withIntermediateDirectories: true)
        let document = workspace.storage.sourceURL(source)
        try Data("Notes".utf8).write(to: document)
        #expect(Set(model.revealURLs(for: recording, storage: workspace.storage)) == Set([audio, document]))
        try FileManager.default.removeItem(at: audio)
        #expect(model.revealURLs(for: recording, storage: workspace.storage) == [document])
        try FileManager.default.removeItem(at: document)
        #expect(model.revealURLs(for: recording, storage: workspace.storage).isEmpty)
        let empty = Recording(title: "Empty", audioFileName: "", originalFileName: "", duration: 0)
        #expect(model.revealURLs(for: empty, storage: workspace.storage).isEmpty)
    }

    @Test func deleteRemovesManagedFilesAndHistoryButPreservesOriginalAndOtherWorkspace() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let original = try workspace.makeAudio()
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let model = LibraryViewModel(importer: AudioImportService(storage: workspace.storage))
        let repository = SwiftDataRecordingRepository(context: context, storage: workspace.storage)
        await model.importURLs([original], into: repository)
        let recording = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        let ownedAudio = workspace.storage.recordingURL(fileName: recording.audioFileName)
        let source = RecordingSource(type: .document, displayName: "Notes", originalFilename: "notes.txt", localFileReference: "notes.txt")
        source.recording = recording
        context.insert(source)
        let sourceDirectory = workspace.storage.sourceDirectory(id: source.id)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data("Notes".utf8).write(to: workspace.storage.sourceURL(source))
        recording.transcript = Transcript()
        recording.summary = Summary(text: "Summary")
        let session = ChatSession()
        session.messages = [ChatMessage(role: .assistant, text: "Answer")]
        recording.chatSessions = [session]
        recording.generationRecords = [GenerationRecord(recording: recording, feature: .summary, provider: nil,
            model: nil, presetName: nil, outputLength: .detailed, settings: nil)]
        let other = Recording(title: "Keep", audioFileName: "", originalFileName: "", duration: 0)
        context.insert(other)
        try context.save()
        model.delete(recording, using: repository)
        #expect(model.selection == nil)
        #expect(model.error == nil)
        #expect(!FileManager.default.fileExists(atPath: ownedAudio.path))
        #expect(!FileManager.default.fileExists(atPath: sourceDirectory.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.id) == [other.id])
        #expect(try context.fetchCount(FetchDescriptor<RecordingSource>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Transcript>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Summary>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ChatMessage>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<GenerationRecord>()) == 0)
    }

    @Test func deleteEmptyWorkspacePreservesUnrelatedSelectionAndBlocksProcessing() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = Recording(title: "Empty", audioFileName: "", originalFileName: "", duration: 0)
        context.insert(recording)
        let generation = GenerationRecord(recording: recording, feature: .chat, provider: nil, model: nil,
            presetName: nil, outputLength: .detailed, settings: nil, status: .inProgress)
        recording.generationRecords = [generation]
        try context.save()
        let model = LibraryViewModel()
        let selection = UUID()
        model.selection = selection
        let repository = SwiftDataRecordingRepository(context: context, storage: workspace.storage)
        #expect(!model.canDelete(recording))
        model.delete(recording, using: repository)
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 1)
        #expect(model.error?.kind == .workspace)
        generation.statusRaw = GenerationStatus.cancelled.rawValue
        model.error = nil
        model.delete(recording, using: repository)
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 0)
        #expect(model.selection == selection)
    }
}

@MainActor
private struct FailingRepository: RecordingStoring {
    func save(_ audio: ImportedAudio) throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}
