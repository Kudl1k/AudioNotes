import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct SummaryRepositoryTests {
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
