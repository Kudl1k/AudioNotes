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
        #expect(model.importError?.contains("invalid.wav") == true)
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
        #expect(model.importError != nil)
        #expect(!model.isImporting)
    }
}

@MainActor
private struct FailingRepository: RecordingStoring {
    func save(_ audio: ImportedAudio) throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}
