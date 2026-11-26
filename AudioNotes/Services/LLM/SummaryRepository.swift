import Foundation
import SwiftData

struct SummaryNamingSnapshot {
    let recordingTitle: String
    let projectID: UUID?
    let projectName: String?

    @MainActor
    init(_ recording: Recording) {
        recordingTitle = recording.title
        projectID = recording.project?.id
        projectName = recording.project?.name
    }
}

@MainActor
protocol SummaryStoring {
    func save(_ newSummary: Summary, for recording: Recording) throws
    func save(_ newSummary: Summary, for recording: Recording, naming snapshot: SummaryNamingSnapshot?) throws
    func record(_ generation: GenerationRecord) throws
    func makeCurrent(_ summary: Summary, for recording: Recording) throws
    func delete(_ summary: Summary, for recording: Recording) throws
}

extension SummaryStoring {
    func save(_ newSummary: Summary, for recording: Recording, naming snapshot: SummaryNamingSnapshot?) throws {
        try save(newSummary, for: recording)
    }
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
        try save(newSummary, for: recording, naming: nil)
    }

    func save(_ newSummary: Summary, for recording: Recording, naming snapshot: SummaryNamingSnapshot?) throws {
        let title = newSummary.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let hasUsableTitle = !title.isEmpty && title.count <= 120
        let previousTitle = recording.title
        let previousSummary = recording.summary
        let previousHistory = recording.summaryHistory
        let previousHistoricalRecording = previousSummary?.historicalRecording
        let project = recording.project
        let previousProjectName = project?.name
        let previousProjectDate = project?.updatedAt

        if let snapshot, hasUsableTitle {
            if recording.title == snapshot.recordingTitle, recording.title != title {
                recording.title = title
                project?.updatedAt = .now
            }
            if let project, project.id == snapshot.projectID, project.name == snapshot.projectName,
               previousSummary == nil, previousHistory.isEmpty,
               !project.recordings.contains(where: { $0.summary != nil || !$0.summaryHistory.isEmpty }) {
                project.name = title
                project.updatedAt = .now
            }
        }
        if let previousSummary, previousSummary.id != newSummary.id {
            if !recording.summaryHistory.contains(where: { $0.id == previousSummary.id }) {
                recording.summaryHistory.append(previousSummary)
            }
            previousSummary.historicalRecording = recording
        }
        recording.summary = newSummary
        newSummary.recording = recording
        context.insert(newSummary)
        do {
            try context.save()
        } catch {
            recording.title = previousTitle
            if let project, let previousProjectName, let previousProjectDate {
                project.name = previousProjectName
                project.updatedAt = previousProjectDate
            }
            if previousSummary?.id != newSummary.id {
                recording.summary = previousSummary
                context.delete(newSummary)
                previousSummary?.historicalRecording = previousHistoricalRecording
                recording.summaryHistory = previousHistory
            }
            throw error
        }
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
