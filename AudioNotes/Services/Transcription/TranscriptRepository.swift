import Foundation
import SwiftData

@MainActor
protocol TranscriptStoring {
    func save(_ transcript: Transcript, for recording: Recording) throws
    func record(_ generation: GenerationRecord) throws
}

extension TranscriptStoring {
    func record(_ generation: GenerationRecord) throws {}
}

@MainActor
struct SwiftDataTranscriptRepository: TranscriptStoring {
    private let container: ModelContainer
    let context: ModelContext
    private let saveChanges: (ModelContext) throws -> Void

    init(context: ModelContext, saveChanges: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = context.container
        self.context = context
        self.saveChanges = saveChanges
    }

    func record(_ generation: GenerationRecord) throws {
        context.insert(generation)
        try context.save()
    }

    func save(_ transcript: Transcript, for recording: Recording) throws {
        guard transcript.recording == nil, transcript.historicalRecording == nil, transcript.source == nil else {
            throw TranscriptHistoryError.invalidVersion
        }
        guard !transcript.segments.isEmpty, transcript.segments.allSatisfy({
            $0.startTime.isFinite && $0.endTime.isFinite && $0.startTime >= 0 &&
            $0.endTime >= $0.startTime && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { throw TranscriptionError.invalidTranscript }

        let segments = transcript.segments
        let previous = recording.transcript
        context.insert(transcript)
        if let previous {
            previous.recording = nil
            previous.historicalRecording = recording
            if !recording.transcriptHistory.contains(where: { $0.id == previous.id }) {
                recording.transcriptHistory.append(previous)
            }
        }
        recording.transcript = transcript
        let primary = recording.sources.first(where: \.isPrimaryAudio)
        let previousStatus = primary?.status
        primary?.status = .ready
        do {
            try saveChanges(context)
        } catch {
            // Undo only this graph; a global rollback could discard unrelated edits.
            if let previousStatus { primary?.status = previousStatus }
            recording.transcriptHistory.removeAll { $0.id == previous?.id }
            previous?.historicalRecording = nil
            recording.transcript = previous
            previous?.recording = recording
            transcript.recording = nil
            for segment in segments { context.delete(segment) }
            context.delete(transcript)
            throw error
        }
    }

    func makeCurrent(_ transcript: Transcript, for recording: Recording) throws {
        guard let current = recording.transcript,
              recording.transcriptHistory.contains(where: { $0.id == transcript.id }) else {
            throw TranscriptHistoryError.invalidVersion
        }
        recording.transcriptHistory.removeAll { $0.id == transcript.id }
        transcript.historicalRecording = nil
        current.recording = nil
        current.historicalRecording = recording
        if !recording.transcriptHistory.contains(where: { $0.id == current.id }) {
            recording.transcriptHistory.append(current)
        }
        recording.transcript = transcript
        transcript.recording = recording
        do {
            try saveChanges(context)
        } catch {
            recording.transcriptHistory.removeAll { $0.id == current.id }
            current.historicalRecording = nil
            transcript.recording = nil
            transcript.historicalRecording = recording
            if !recording.transcriptHistory.contains(where: { $0.id == transcript.id }) {
                recording.transcriptHistory.append(transcript)
            }
            recording.transcript = current
            current.recording = recording
            throw error
        }
    }

    func delete(_ transcript: Transcript, for recording: Recording) throws {
        guard recording.transcript?.id != transcript.id,
              recording.transcriptHistory.contains(where: { $0.id == transcript.id }) else {
            throw TranscriptHistoryError.invalidVersion
        }
        // A cascade marks the entire graph deleted. Snapshot its domain IDs and
        // values before deletion so a failed save can rebuild only this version.
        let recovery = Transcript(id: transcript.id, languageCode: transcript.languageCode,
                                  createdAt: transcript.createdAt, sourceName: transcript.sourceName,
                                  isMock: transcript.isMock)
        recovery.generationID = transcript.generationID
        recovery.segments = transcript.segments.map {
            TranscriptSegment(id: $0.id, position: $0.position, startTime: $0.startTime,
                              endTime: $0.endTime, text: $0.text, speaker: $0.speaker)
        }
        recording.transcriptHistory.removeAll { $0.id == transcript.id }
        transcript.historicalRecording = nil
        context.delete(transcript)
        do {
            try saveChanges(context)
        } catch {
            context.insert(recovery)
            recovery.historicalRecording = recording
            if !recording.transcriptHistory.contains(where: { $0.id == recovery.id }) {
                recording.transcriptHistory.append(recovery)
            }
            throw error
        }
    }
}

enum TranscriptHistoryError: LocalizedError {
    case invalidVersion
    var errorDescription: String? { "Only an older transcript version belonging to this recording can be restored or deleted." }
}
