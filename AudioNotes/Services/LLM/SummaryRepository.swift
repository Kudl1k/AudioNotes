import Foundation
import SwiftData

@MainActor
protocol SummaryStoring {
    func save(_ newSummary: Summary, for recording: Recording) throws
    func record(_ generation: GenerationRecord) throws
    func makeCurrent(_ summary: Summary, for recording: Recording) throws
    func delete(_ summary: Summary, for recording: Recording) throws
}

extension SummaryStoring {
    func record(_ generation: GenerationRecord) throws {}
    func makeCurrent(_ summary: Summary, for recording: Recording) throws {}
    func delete(_ summary: Summary, for recording: Recording) throws {}
}

@MainActor
final class SwiftDataSummaryRepository: SummaryStoring {
    private let container: ModelContainer
    private let context: ModelContext

    init(context: ModelContext) {
        self.container = context.container
        self.context = context
    }

    func save(_ newSummary: Summary, for recording: Recording) throws {
        if let oldSummary = recording.summary, oldSummary.id != newSummary.id {
            if !recording.summaryHistory.contains(where: { $0.id == oldSummary.id }) {
                recording.summaryHistory.append(oldSummary)
            }
            oldSummary.historicalRecording = recording
        }
        recording.summary = newSummary
        newSummary.recording = recording
        context.insert(newSummary)
        try context.save()
    }

    func makeCurrent(_ summary: Summary, for recording: Recording) throws {
        guard let current = recording.summary,
              recording.summaryHistory.contains(where: { $0.id == summary.id }) else { return }
        recording.summaryHistory.removeAll { $0.id == summary.id }
        current.recording = nil
        current.historicalRecording = recording
        summary.historicalRecording = nil
        summary.recording = recording
        recording.summary = summary
        try context.save()
    }

    func record(_ generation: GenerationRecord) throws {
        context.insert(generation)
        try context.save()
    }

    func delete(_ summary: Summary, for recording: Recording) throws {
        guard summary.id != recording.summary?.id else { return }
        recording.summaryHistory.removeAll { $0.id == summary.id }
        context.delete(summary)
        try context.save()
    }
}
