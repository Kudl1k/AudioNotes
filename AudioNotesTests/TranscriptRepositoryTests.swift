import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct TranscriptRepositoryTests {
    @Test func roundTripPreservesChronologySpeakersAndMockProvenance() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        var recordingID: UUID?
        do {
            let container = try workspace.storage.makeContainer()
            let context = ModelContext(container)
            let recording = try await workspace.makeRecording(in: context)
            recordingID = recording.id
            let transcript = Transcript(languageCode: "en", sourceName: "Mock transcription", isMock: true)
            // Deliberately conflict timestamp order with provider position order.
            transcript.segments = [
                TranscriptSegment(position: 0, startTime: 0.6, endTime: 1, text: "Last", speaker: "Alex"),
                TranscriptSegment(position: 2, startTime: 0, endTime: 0.2, text: "Second"),
                TranscriptSegment(position: 1, startTime: 0, endTime: 0.1, text: "First", speaker: "Sam")
            ]
            try SwiftDataTranscriptRepository(context: context).save(transcript, for: recording)
        }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        let recording = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        let transcript = try #require(recording.transcript)
        #expect(recording.id == recordingID)
        #expect(transcript.recording?.id == recordingID)
        #expect(transcript.orderedSegments.map(\.text) == ["First", "Second", "Last"])
        #expect(transcript.orderedSegments.map(\.speaker) == ["Sam", nil, "Alex"])
        #expect(transcript.isMock)
        #expect(transcript.sourceName == "Mock transcription")
        #expect(transcript.languageCode == "en")
        #expect(transcript.segments.allSatisfy { $0.transcript?.id == transcript.id })
    }

    @Test func rejectsEmptyOrInvalidTranscriptsWithoutSaving() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        let repository = SwiftDataTranscriptRepository(context: context)
        #expect(throws: TranscriptionError.self) { try repository.save(Transcript(), for: recording) }
        for times in [(-1.0, 1.0), (1.0, 0.0), (Double.nan, 1.0), (0.0, Double.infinity)] {
            let transcript = sampleTranscript()
            transcript.segments[0].startTime = times.0
            transcript.segments[0].endTime = times.1
            #expect(throws: TranscriptionError.self) { try repository.save(transcript, for: recording) }
        }
        #expect(recording.transcript == nil)
        #expect(try context.fetchCount(FetchDescriptor<Transcript>()) == 0)
    }

    @Test func regenerationArchivesPreviousTranscript() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        let repository = SwiftDataTranscriptRepository(context: context)
        let first = sampleTranscript()
        try repository.save(first, for: recording)
        let second = sampleTranscript()
        try repository.save(second, for: recording)
        #expect(recording.transcript?.id == second.id)
        #expect(recording.transcriptHistory.map(\.id) == [first.id])
        #expect(first.recording == nil)
        #expect(first.historicalRecording?.id == recording.id)
        #expect(try context.fetchCount(FetchDescriptor<Transcript>()) == 2)
    }

    @Test func historySurvivesReopeningAndSupportsRestoreDeleteAndRecordingCascade() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        var oldID: UUID!
        var newID: UUID!
        let generationID = UUID()
        do {
            let container = try workspace.storage.makeContainer()
            let context = ModelContext(container)
            let recording = try await workspace.makeRecording(in: context)
            let repository = SwiftDataTranscriptRepository(context: context)
            let first = sampleTranscript()
            first.generationID = generationID
            oldID = first.id
            try repository.save(first, for: recording)
            let second = sampleTranscript()
            newID = second.id
            try repository.save(second, for: recording)
        }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        let recording = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        let repository = SwiftDataTranscriptRepository(context: context)
        let old = try #require(recording.transcriptHistory.first)
        #expect(old.id == oldID)
        #expect(old.generationID == generationID)
        #expect(old.segments.count == 1)
        try repository.makeCurrent(old, for: recording)
        #expect(recording.transcript?.id == oldID)
        #expect(recording.transcriptHistory.map(\.id) == [newID])
        #expect(throws: TranscriptHistoryError.self) { try repository.delete(old, for: recording) }
        #expect(throws: TranscriptHistoryError.self) { try repository.makeCurrent(sampleTranscript(), for: recording) }
        let historical = try #require(recording.transcriptHistory.first)
        let segmentIDs = historical.segments.map(\.id)
        let failing = SwiftDataTranscriptRepository(context: context) { _ in throw CocoaError(.fileWriteOutOfSpace) }
        #expect(throws: CocoaError.self) { try failing.delete(historical, for: recording) }
        try context.save()
        let freshContext = ModelContext(container)
        let persisted = try #require(freshContext.fetch(FetchDescriptor<Recording>()).first)
        #expect(persisted.transcript?.id == oldID)
        #expect(persisted.transcriptHistory.first?.id == newID)
        #expect(persisted.transcriptHistory.first?.segments.map(\.id) == segmentIDs)
        try repository.delete(try #require(recording.transcriptHistory.first), for: recording)
        #expect(recording.transcriptHistory.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<Transcript>()) == 1)
        try repository.save(sampleTranscript(), for: recording)
        context.delete(recording)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Transcript>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSegment>()) == 0)
    }

    @Test func failedReplacementAndRestorePreserveCurrentVersionAndUnrelatedEdits() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        let repository = SwiftDataTranscriptRepository(context: context)
        let first = sampleTranscript()
        try repository.save(first, for: recording)
        let failing = SwiftDataTranscriptRepository(context: context) { _ in throw CocoaError(.fileWriteOutOfSpace) }
        recording.title = "Pending edit"
        #expect(throws: CocoaError.self) { try failing.save(sampleTranscript(), for: recording) }
        #expect(recording.transcript?.id == first.id)
        #expect(recording.transcriptHistory.isEmpty)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Transcript>()) == 1)
        #expect(recording.title == "Pending edit")
        let second = sampleTranscript()
        try repository.save(second, for: recording)
        #expect(throws: CocoaError.self) { try failing.makeCurrent(first, for: recording) }
        #expect(recording.transcript?.id == second.id)
        #expect(recording.transcriptHistory.map(\.id) == [first.id])
        #expect(throws: CocoaError.self) { try failing.delete(first, for: recording) }
        try context.save()
        #expect(recording.transcriptHistory.map(\.id) == [first.id])
        #expect(recording.transcriptHistory.first?.segments.count == 1)
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSegment>()) == 2)
    }
}
