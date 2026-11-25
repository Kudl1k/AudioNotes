import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct SummaryRepositoryTests {
    @Test func firstGeneratedSummaryTitlesProjectAndRegenerationPreservesItsName() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(name: "Initial project")
        let recording = Recording(title: "Imported audio", audioFileName: "audio.m4a", originalFileName: "audio.m4a", duration: 10)
        recording.project = project
        let transcript = Transcript()
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Review the architecture.")]
        recording.transcript = transcript
        context.insert(project)
        context.insert(recording)
        try context.save()

        let repository = SwiftDataSummaryRepository(context: context)
        let resolver = FixedLLMProviderResolver(provider: MockLLMProvider(delayNanoseconds: 0))
        let model = SummaryViewModel(recording: recording, resolver: resolver)
        let task = try #require(model.generateSummary(using: repository))
        await task.value

        let title = try #require(recording.summary?.title)
        #expect(!title.isEmpty)
        #expect(project.name == title)
        #expect(recording.title == title)
        #expect(recording.audioFileName == "audio.m4a")
        let reloadedContext = ModelContext(container)
        #expect(try reloadedContext.fetch(FetchDescriptor<Project>()).first?.name == title)

        let replacement = Summary(overview: "Revised overview", preset: .general, title: "Different Topic")
        try repository.save(replacement, for: recording, naming: SummaryNamingSnapshot(recording))
        #expect(project.name == title)
        #expect(recording.summary?.title == "Different Topic")
        #expect(recording.title == "Different Topic")
    }

    @Test func pendingSummaryPreservesProjectRename() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(name: "Original")
        let recording = Recording(title: "Test", audioFileName: "audio.m4a", originalFileName: "audio.m4a", duration: 10)
        recording.project = project
        context.insert(project)
        context.insert(recording)
        try context.save()

        let snapshot = SummaryNamingSnapshot(recording)
        project.name = "Manually renamed"
        recording.title = "Manually renamed recording"
        let summary = Summary(overview: "Overview", preset: .general, title: "Generated Name")
        try SwiftDataSummaryRepository(context: context).save(summary, for: recording, naming: snapshot)

        #expect(project.name == "Manually renamed")
        #expect(recording.title == "Manually renamed recording")
        #expect(recording.summary?.title == "Generated Name")
    }

    @Test func regenerationPreservesOlderSummaryVersions() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }

        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let repository = SwiftDataSummaryRepository(context: context)

        let recording = Recording(title: "Test", audioFileName: "audio.m4a", originalFileName: "audio.m4a", duration: 10)
        context.insert(recording)
        try context.save()

        let initialSummary = Summary(overview: "Initial summary", preset: .general, title: "Initial Topic")
        try repository.save(initialSummary, for: recording)

        #expect(recording.summary?.id == initialSummary.id)
        #expect(recording.summary?.overview == "Initial summary")
        #expect(recording.summaryHistory.isEmpty)

        let updatedSummary = Summary(overview: "Updated summary", preset: .meeting, title: "Updated Topic")
        try repository.save(updatedSummary, for: recording)

        #expect(recording.summary?.id == updatedSummary.id)
        #expect(recording.summary?.overview == "Updated summary")
        #expect(recording.summary?.preset == .meeting)
        #expect(recording.summary?.title == "Updated Topic")
        #expect(recording.summaryHistory.count == 1)
        #expect(recording.summaryHistory.contains(where: { $0.id == initialSummary.id }))
        #expect(recording.summaryHistory.first?.title == "Initial Topic")

        let reloadedContext = ModelContext(container)
        let reloaded = try #require(reloadedContext.fetch(FetchDescriptor<Recording>()).first)
        #expect(reloaded.summary?.title == "Updated Topic")
        #expect(reloaded.summaryHistory.first?.title == "Initial Topic")

        try repository.makeCurrent(initialSummary, for: recording)
        #expect(recording.summary?.id == initialSummary.id)
        #expect(recording.summary?.title == "Initial Topic")
        #expect(recording.summaryHistory.count == 1)
        #expect(recording.summaryHistory.first?.id == updatedSummary.id)

        try repository.delete(updatedSummary, for: recording)
        #expect(recording.summary?.id == initialSummary.id)
        #expect(recording.summaryHistory.isEmpty)
    }
}
