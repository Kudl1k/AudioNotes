import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct AudioRecordingJourneyTests {
    @Test func batchReportsFactualProgressAndKeepsSuccessfulItems() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let good = try workspace.makeAudio()
        let bad = workspace.root.appending(path: "bad.m4a")
        try Data("not audio".utf8).write(to: bad)
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let library = LibraryViewModel(importer: AudioImportService(storage: workspace.storage))
        var steps: [Int] = []
        let result = await library.importURLs([good, bad, good], into: SwiftDataRecordingRepository(context: context, storage: workspace.storage), progress: { steps.append($0) })
        #expect(result.importedCount == 2)
        #expect(result.failures.count == 1)
        #expect(result.failures[0].contains("This file does not contain playable audio."))
        #expect(!result.cancelled)
        #expect(steps == [1, 2, 3])
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 2)
        #expect(try workspace.importedFiles().count == 2)
    }

    @Test func cancellationAfterCopyRollsBackWithoutCreatingRecording() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let importer = CancellingAudioImporter(service: AudioImportService(storage: workspace.storage))
        let library = LibraryViewModel(importer: importer)
        let source = try workspace.makeAudio()
        let result = await Task {
            await library.importURLs([source], into: SwiftDataRecordingRepository(context: context, storage: workspace.storage))
        }.value
        #expect(result.cancelled)
        #expect(result.importedCount == 0)
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 0)
        #expect(try workspace.importedFiles().isEmpty)
    }

    @Test func deterministicPlaybackPauseSeekCompletionAndReplay() {
        let engine = TestPlaybackEngine()
        let player = AudioPlaybackService(makePlayer: { _ in engine })
        player.load(url: URL(fileURLWithPath: "/synthetic.wav"))
        player.togglePlayback()
        #expect(player.isPlaying)
        player.seek(to: 12)
        #expect(engine.currentTime == 12)
        #expect(player.isPlaying)
        player.togglePlayback()
        #expect(!player.isPlaying)
        #expect(engine.currentTime == 12)
        let segment = TranscriptSegment(position: 0, startTime: 23, endTime: 25, text: "Ahoj")
        player.seek(to: segment.startTime)
        #expect(engine.currentTime == 23)
        player.togglePlayback()
        engine.currentTime = 30
        engine.isPlaying = false
        player.refreshProgress()
        #expect(!player.isPlaying)
        #expect(player.currentTime == 30)
        player.togglePlayback()
        #expect(engine.currentTime == 0)
        #expect(engine.playCalls == 3)
        player.stop()
    }

    @Test func summarySnapshotKeepsStructuredSectionsAndCzechMarkdown() {
        let summary = Summary(overview: "## Přehled\n\n[Odkaz](https://example.com)\n\n```swift\nlet x = 1\n```", keyPoints: [KeyPoint(text: "Žluťoučký kůň")],
                              actionItems: [ActionItem(text: "Úkol", assignee: "Jiří", dueDate: "zítra")],
                              additionalSections: [SummarySection(title: "Poznámky", items: ["Další bod"])], title: "Schůzka")
        let text = SummaryMarkdownContent.text(summary)
        #expect(text.contains("Žluťoučký kůň"))
        #expect(text.contains("Assignee: Jiří"))
        #expect(text.contains("## Poznámky"))
        let document = MarkdownDocument(text)
        #expect(document.blocks.contains { if case .code = $0 { true } else { false } })
        #expect(document.blocks.contains { if case .list = $0 { true } else { false } })
    }

    @Test func deletingProjectMemberPreservesProjectAndOtherRecording() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let audio = try await AudioImportService(storage: workspace.storage).importFile(at: workspace.makeAudio())
        let repository = SwiftDataRecordingRepository(context: context, storage: workspace.storage)
        try repository.save(audio)
        let recording = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        let project = Project(name: "Keep project")
        context.insert(project)
        recording.project = project
        let other = Recording(title: "Keep recording", audioFileName: "", originalFileName: "", duration: 0)
        context.insert(other)
        other.project = project
        try context.save()
        try repository.delete(recording)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 1)
        #expect(project.recordings.map(\.id) == [other.id])
        #expect(try workspace.importedFiles().isEmpty)
    }
}

private actor CancellingAudioImporter: AudioImporting {
    let service: AudioImportService
    init(service: AudioImportService) { self.service = service }
    func importFile(at source: URL) async throws -> ImportedAudio {
        let result = try await service.importFile(at: source)
        withUnsafeCurrentTask { $0?.cancel() }
        return result
    }
    func discard(_ imported: ImportedAudio) async throws { try await service.discard(imported) }
}

@MainActor
private final class TestPlaybackEngine: AudioPlaybackEngine {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval { 30 }
    var isPlaying = false
    var playCalls = 0
    func prepareToPlay() -> Bool { true }
    func play() -> Bool { playCalls += 1; isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}
