import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct ProjectImportTests {
    @Test func mixedBatchKeepsSupportedFilesAndReportsUnsupportedWithoutTranscribing() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let project = try SwiftDataProjectRepository(context: context).create(name: "Course", description: nil)
        var urls: [URL] = []
        for index in 1...3 { urls.append(try workspace.makeAudio(name: "lecture\(index).wav")) }
        for index in 1...2 {
            let url = workspace.root.appending(path: "slides\(index).pdf")
            try writeSourceTestPDF(["Slides \(index)", "Second page"], to: url)
            urls.append(url)
        }
        for index in 1...2 {
            let url = workspace.root.appending(path: "image\(index).png")
            try writeSourceTestImage(sourceTestImage(text: "Image \(index)"), to: url, type: "public.png")
            urls.append(url)
        }
        let notes = workspace.root.appending(path: "notes.md")
        try "# Notes\nOperating systems".write(to: notes, atomically: true, encoding: .utf8)
        urls.append(notes)
        let unsupported = workspace.root.appending(path: "archive.zip")
        try Data("unsupported".utf8).write(to: unsupported)
        urls.append(unsupported)
        let queue = ProjectImportQueue(storage: workspace.storage, processor: NativeSourceProcessingService(ocr: FixtureOCR()))
        queue.enqueue(urls, to: project, context: context)
        await queue.waitUntilIdle()
        #expect(project.recordings.count == 3)
        #expect(project.sources.count == 5)
        #expect(project.recordings.allSatisfy { $0.project?.id == project.id && $0.transcript == nil })
        #expect(project.sources.allSatisfy { $0.recording == nil && $0.status == .ready })
        #expect(project.sources.filter { $0.type == .pdf }.allSatisfy { $0.textUnits.count == 2 })
        #expect(project.sources.filter { $0.type == .image }.allSatisfy { $0.textUnits.first?.origin == .ocr })
        #expect(queue.items.filter { $0.state == .added }.count == 8)
        #expect(queue.items.contains { $0.filename == "archive.zip" && !$0.isActive && $0.state != .added })
        #expect(try context.fetchCount(FetchDescriptor<GenerationRecord>()) == 0)
        #expect(try workspace.importedFiles().count == 3)
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        queue.enqueue([notes, notes], to: project, context: context)
        await queue.waitUntilIdle()
        #expect(project.sources.count == 5)
        #expect(queue.items.count == 10)
        #expect(queue.items.last?.statusText == SourceImportError.duplicate.localizedDescription)
    }

    @Test func cancelBeforeStartingPreservesNothingAndAllowsLaterImport() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let project = try SwiftDataProjectRepository(context: context).create(name: "Cancel", description: nil)
        let file = workspace.root.appending(path: "notes.txt")
        try "Notes".write(to: file, atomically: true, encoding: .utf8)
        let queue = ProjectImportQueue(storage: workspace.storage)
        queue.enqueue([file], to: project, context: context)
        queue.cancelRemaining(for: project.id)
        await queue.waitUntilIdle()
        #expect(project.sources.isEmpty)
        #expect(queue.items.first?.state == .cancelled)
        queue.enqueue([file], to: project, context: context)
        await queue.waitUntilIdle()
        #expect(project.sources.count == 1)
    }

    @Test func failedExtractionRetriesSameManagedSource() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let project = try SwiftDataProjectRepository(context: context).create(name: "Retry", description: nil)
        let file = workspace.root.appending(path: "notes.txt")
        try "Valid source".write(to: file, atomically: true, encoding: .utf8)
        let processor = RetryProjectProcessor()
        let queue = ProjectImportQueue(storage: workspace.storage, processor: processor)
        queue.enqueue([file], to: project, context: context)
        await queue.waitUntilIdle()
        let source = try #require(project.sources.first)
        let id = source.id
        #expect(source.status == .failed)
        queue.retry(source, in: project, context: context)
        await queue.waitUntilIdle()
        #expect(source.id == id)
        #expect(project.sources.count == 1)
        #expect(source.status == .ready)
        #expect(source.textUnits.first?.text == "Recovered")
    }

    @Test func deletionWaitsForExtractionCancellationAndPreventsNewWrites() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let repository = SwiftDataProjectRepository(context: context, storage: workspace.storage)
        let project = try repository.create(name: "Active", description: nil)
        let file = workspace.root.appending(path: "notes.txt")
        try "Notes".write(to: file, atomically: true, encoding: .utf8)
        let processor = BlockingProjectProcessor()
        let queue = ProjectImportQueue(storage: workspace.storage, processor: processor)
        queue.enqueue([file], to: project, context: context)
        await processor.waitUntilStarted()
        let source = try #require(project.sources.first)
        #expect(source.status == .processing)
        #expect(throws: ProjectEditingError.self) { try repository.delete(project, deletingRecordings: false) }
        let directory = workspace.storage.sourceDirectory(id: source.id)
        await queue.cancelAndWait(for: project.id)
        queue.enqueue([file], to: project, context: context)
        #expect(!queue.hasJobs(for: project.id))
        try repository.delete(project, deletingRecordings: false)
        await queue.waitUntilIdle()
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RecordingSource>()) == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func oneWorkerBoundsExtractionAcrossProjectsWhileNavigationChanges() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let repository = SwiftDataProjectRepository(context: context)
        let a = try repository.create(name: "A", description: nil)
        let b = try repository.create(name: "B", description: nil)
        let file = workspace.root.appending(path: "notes.md")
        try "Notes".write(to: file, atomically: true, encoding: .utf8)
        let processor = CountingProjectProcessor()
        let queue = ProjectImportQueue(storage: workspace.storage, processor: processor)
        let library = LibraryViewModel()
        queue.enqueue([file], to: a, context: context)
        queue.enqueue([file], to: b, context: context)
        library.selectProject(b.id)
        await queue.waitUntilIdle()
        #expect(await processor.maximum == 1)
        #expect(a.sources.count == 1 && b.sources.count == 1)
        #expect(library.projectSelection == b.id)
    }
}

private actor RetryProjectProcessor: SourceProcessing {
    var calls = 0
    func process(url: URL, type: RecordingSourceType, progress: @escaping SourceProcessingProgressHandler) async throws -> SourceProcessingResult {
        calls += 1
        if calls == 1 { throw SourceImportError.noText }
        return .init(units: [.init(position: 0, text: "Recovered", origin: .nativeText, locator: .document(section: "Notes", start: 0, end: 9))], metadata: .document(characterCount: 9), warnings: [])
    }
}
private actor BlockingProjectProcessor: SourceProcessing {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func process(url: URL, type: RecordingSourceType, progress: @escaping SourceProcessingProgressHandler) async throws -> SourceProcessingResult {
        started = true; waiter?.resume(); waiter = nil
        try await Task.sleep(for: .seconds(30))
        throw SourceImportError.noText
    }
}
private actor CountingProjectProcessor: SourceProcessing {
    private var active = 0
    private(set) var maximum = 0
    func process(url: URL, type: RecordingSourceType, progress: @escaping SourceProcessingProgressHandler) async throws -> SourceProcessingResult {
        active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(5))
        return .init(units: [.init(position: 0, text: "Notes", origin: .nativeText, locator: .document(section: "Notes", start: 0, end: 5))], metadata: .document(characterCount: 5), warnings: [])
    }
}
