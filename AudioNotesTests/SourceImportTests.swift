import Foundation
import Testing
import SwiftData
@testable import AudioNotes

struct SourceImportTests {
    @Test func managedCopySurvivesExternalDeletionAndHashDetectsRenamedDuplicate() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let url = workspace.root.appending(path: "notes.md")
        let data = Data("# Czech\nŽluťoučký kůň".utf8)
        try data.write(to: url)
        let importer = SourceImportService(storage: workspace.storage)
        let imported = try await importer.importFile(url, existingHashes: [])
        let copy = workspace.storage.sourceURL(id: imported.id, filename: imported.filename)
        try FileManager.default.removeItem(at: url)
        #expect(try Data(contentsOf: copy) == data)
        let renamed = workspace.root.appending(path: "different.md"); try data.write(to: renamed)
        await #expect(throws: SourceImportError.duplicate) { try await importer.importFile(renamed, existingHashes: [imported.hash]) }
        #expect(try FileManager.default.contentsOfDirectory(at: workspace.storage.sourcesURL, includingPropertiesForKeys: nil).count == 1)
        try await importer.discard(imported)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }
    @Test func cancellationUnsupportedAndSymbolicLinksDoNotLeaveCopies() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "script.docx"); try Data("not a document".utf8).write(to: file)
        let importer = SourceImportService(storage: workspace.storage)
        await #expect(throws: SourceImportError.unsupported) { try await importer.importFile(file, existingHashes: []) }
        let original = workspace.root.appending(path: "original.txt"); try Data("Text".utf8).write(to: original)
        let link = workspace.root.appending(path: "symlink.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        await #expect(throws: SourceImportError.invalidFile) { try await importer.importFile(link, existingHashes: []) }
        let task = Task { try await importer.importFile(original, existingHashes: []) }; task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(!FileManager.default.fileExists(atPath: workspace.storage.sourcesURL.path))
    }
    @Test func additionalAudioUsesManagedCopyAndDuration() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = try workspace.makeAudio()
        let imported = try await SourceImportService(storage: workspace.storage).importFile(file, existingHashes: [])
        #expect(imported.type == .audio)
        #expect(abs((imported.duration ?? 0) - 1) < 0.01)
    }
}

@MainActor
struct SourceWorkspaceImportTests {
    @Test func multipleFilesProcessIndependentlyAndAudioIsNotHashedForImageImports() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let recording = Recording(title: "Lecture", audioFileName: "missing-large-audio.m4a", originalFileName: "Lecture", duration: 100)
        context.insert(recording)
        let model = SourcesViewModel(recording: recording, storage: workspace.storage, processor: NativeSourceProcessingService(ocr: FixtureOCR()))
        model.prepare(context: context)
        let text = workspace.root.appending(path: "assignment.md")
        try "# Assignment\nČeské poznámky".write(to: text, atomically: true, encoding: .utf8)
        let pdf = workspace.root.appending(path: "slides.pdf")
        try writeSourceTestPDF(["Lecture slides"], to: pdf)
        let image = workspace.root.appending(path: "whiteboard.png")
        try writeSourceTestImage(sourceTestImage(text: "Semaphore"), to: image, type: "public.png")
        await model.importURLs([text, pdf, image], context: context)
        await model.waitForProcessing()
        #expect(model.error == nil)
        #expect(recording.sources.count == 4)
        #expect(recording.sources.filter { !$0.isPrimaryAudio }.allSatisfy { $0.status == .ready })
        #expect(recording.sources.first(where: \.isPrimaryAudio)?.contentHash == nil)
        #expect(model.progress.isEmpty)
        #expect(!model.isImporting)
    }
}
