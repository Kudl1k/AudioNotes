import Foundation
import Testing
@testable import AudioNotes

struct AudioImportServiceTests {
    @Test func copiesAudioAndPreservesOriginal() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let source = try workspace.makeAudio()
        let service = AudioImportService(storage: workspace.storage)
        let audio = try await service.importFile(at: source)
        #expect(audio.title == "Meeting")
        #expect(audio.originalFileName == "Meeting.wav")
        #expect(abs(audio.duration - 1) < 0.01)
        #expect(audio.fileName == audio.id.uuidString + ".wav")
        #expect(try Data(contentsOf: source) == Data(contentsOf: workspace.storage.recordingURL(fileName: audio.fileName)))
        try await service.discard(audio)
        #expect(try workspace.importedFiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func repeatedImportsNeverOverwrite() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let source = try workspace.makeAudio()
        let service = AudioImportService(storage: workspace.storage)
        let first = try await service.importFile(at: source)
        let second = try await service.importFile(at: source)
        #expect(first.fileName != second.fileName)
        #expect(try workspace.importedFiles().count == 2)
    }

    @Test func rejectsNonAudioAndDirectories() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let text = workspace.root.appending(path: "notes.txt")
        try Data("Not audio".utf8).write(to: text)
        let service = AudioImportService(storage: workspace.storage)
        for url in [text, workspace.root, URL(string: "https://example.com/audio.wav")!] {
            await #expect(throws: (any Error).self) { try await service.importFile(at: url) }
        }
        #expect(try workspace.importedFiles().isEmpty)
    }

    @Test func corruptAudioLeavesNoCopy() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let source = workspace.root.appending(path: "broken.wav")
        try Data("Invalid WAV content".utf8).write(to: source)
        let service = AudioImportService(storage: workspace.storage)
        await #expect(throws: (any Error).self) { try await service.importFile(at: source) }
        #expect(try workspace.importedFiles().isEmpty)
    }

    @Test func undecodableAudioReportsUserFacingError() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        for name in ["broken.m4a", "broken.wav"] {
            let source = workspace.root.appending(path: name)
            try Data("not audio data".utf8).write(to: source)
            let service = AudioImportService(storage: workspace.storage)
            do {
                _ = try await service.importFile(at: source)
                Issue.record("Expected \(name) to be rejected")
            } catch let error as AudioImportError {
                #expect(error.localizedDescription == "This file does not contain playable audio.")
            }
        }
        #expect(try workspace.importedFiles().isEmpty)
    }

    @Test func cancellationPreventsImport() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let source = try workspace.makeAudio()
        let service = AudioImportService(storage: workspace.storage)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.importFile(at: source)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try workspace.importedFiles().isEmpty)
    }

    @Test func storageFailurePreservesSource() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let source = try workspace.makeAudio()
        let blocked = workspace.root.appending(path: "blocked")
        try Data().write(to: blocked)
        let service = AudioImportService(storage: LibraryStorage(rootURL: blocked))
        await #expect(throws: (any Error).self) { try await service.importFile(at: source) }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}
