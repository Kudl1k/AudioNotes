import Foundation
import SwiftData
import Testing
@testable import AudioNotes

struct OperationProgressTests {
#if DEBUG
    @MainActor @Test func multipartFixtureReportsRealOrderedCompletionsAndCancellation() async throws {
        let provider = OperationFixtureTranscriptionProvider(partDelay: .zero)
        var statuses: [TranscriptionStatus] = []
        let transcript = try await provider.transcribe(audioURL: URL(filePath: "/fixture.wav"), progress: { _ in },
            status: { statuses.append($0) })
        #expect(statuses.filter { $0.phase == .transcribing }.map(\.completedParts) == [0, 1, 1, 2, 2, 3])
        #expect(statuses.compactMap(\.currentPart) == [1, 1, 2, 2, 3, 3])
        #expect(transcript.orderedSegments.map(\.startTime) == [0, 4, 8])
        #expect(transcript.orderedSegments.last?.endTime == 12)

        let task = Task { @MainActor in
            _ = try await provider.transcribe(audioURL: URL(filePath: "/fixture.wav"), progress: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: TranscriptionError.self) {
            _ = try await provider.transcribe(audioURL: URL(filePath: "/fixture-failure.wav"), progress: { _ in })
        }
    }

    @MainActor @Test func layoutFixturesRemainIsolatedAndIdempotent() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        try OperationPresentationFixtures.prepare(context: container.mainContext, storage: workspace.storage)
        try OperationPresentationFixtures.prepare(context: container.mainContext, storage: workspace.storage)
        let recordings = try container.mainContext.fetch(FetchDescriptor<Recording>())
        #expect(recordings.count == 2)
        #expect(recordings.allSatisfy { $0.transcript == nil && $0.generationRecords.isEmpty })
        #expect(recordings.allSatisfy { FileManager.default.fileExists(atPath: workspace.storage.recordingURL(fileName: $0.audioFileName).path) })
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Project>()) == 1)
    }

    @MainActor @Test func attachmentRetainsMeasuredPartProgressAndClearsItAfterCompletion() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let recording = Recording(title: "Attachment fixture", audioFileName: "", originalFileName: "", duration: 0)
        let source = RecordingSource(type: .audio, displayName: "Audio", originalFilename: "fixture.wav",
            localFileReference: "fixture.wav")
        source.metadata = .audio(duration: 12)
        source.recording = recording
        context.insert(recording)
        context.insert(source)
        try context.save()
        let model = SourcesViewModel(recording: recording, storage: workspace.storage)
        let provider = ObservedOperationFixtureProvider()
        var observedParts: [Int] = []
        provider.observe = {
            if let snapshot = model.transcriptionProgress[source.id], let part = snapshot.currentPart {
                observedParts.append(part)
                #expect(snapshot.totalParts == 3)
                #expect(snapshot.startedAt == model.startedAt[source.id])
                if snapshot.completedParts > 0 {
                    #expect(snapshot.overallProgress == Double(snapshot.completedParts) / 3)
                }
            }
        }
        model.transcribe(source, resolver: FixedTranscriptionProviderResolver(provider: provider), context: context)
        await model.waitForProcessing()
        #expect(observedParts == [1, 1, 2, 2, 3, 3])
        #expect(source.status == .ready)
        #expect(source.transcript?.segments.count == 3)
        #expect(model.startedAt[source.id] == nil)
        #expect(model.transcriptionProgress[source.id] == nil)
        #expect(recording.generationRecords.first?.billingKind == .local)
    }
#endif
    @Test(arguments: [
        (0.0, "0:00"), (1, "0:01"), (59, "0:59"), (60, "1:00"),
        (61, "1:01"), (3599, "59:59"), (3600, "1:00:00"),
        (3738, "1:02:18"), (90061, "25:01:01"), (61.9, "1:01")
    ]) func duration(seconds: Double, expected: String) {
        #expect(OperationDurationFormatter.string(seconds) == expected)
    }

    @Test(arguments: [-1.0, Double.nan, Double.infinity, -Double.infinity, Double(Int.max)])
    func invalidDurationsAreSafe(seconds: Double) {
        #expect(OperationDurationFormatter.string(seconds) == "0:00")
    }

    @Test func elapsedUsesTimestampsRatherThanTickCount() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(OperationDurationFormatter.elapsed(since: start, now: start) == 0)
        // A suspended display can skip every intervening tick and still catch up.
        #expect(OperationDurationFormatter.elapsed(since: start, now: start.addingTimeInterval(91.5)) == 91.5)
        #expect(OperationDurationFormatter.elapsed(since: start, now: start.addingTimeInterval(-5)) == 0)
    }

    @Test func unknownProgressDoesNotInventPercentage() {
        let unknown = OperationProgressValue()
        #expect(unknown.fraction == nil)
        #expect(unknown.percentage == nil)
        #expect(OperationProgressValue(completed: 2, total: 0).fraction == nil)
        #expect(OperationProgressValue(completed: 2, total: -1).total == nil)
    }

    @Test func measuredFractionsAreBounded() {
        #expect(OperationProgressValue(fraction: 0).percentage == "0%")
        #expect(OperationProgressValue(fraction: 1).percentage == "100%")
        #expect(OperationProgressValue(fraction: 0.349).percentage == "34%")
        #expect(OperationProgressValue(fraction: -1).fraction == 0)
        #expect(OperationProgressValue(fraction: 2).fraction == 1)
        #expect(OperationProgressValue(fraction: .nan).fraction == nil)
        #expect(OperationProgressValue(fraction: .infinity).fraction == nil)
    }

    @Test func completedUnitsDescribeMeasuredWork() {
        let parts = OperationProgressValue(completed: 3, total: 12)
        #expect(parts.fraction == 0.25)
        #expect(parts.completed == 3)
        #expect(parts.total == 12)
        #expect(OperationProgressValue(completed: -1, total: 12).fraction == 0)
        #expect(OperationProgressValue(completed: 13, total: 12).fraction == 1)
        // Audio durations can be uneven; a supplied measured fraction wins.
        #expect(OperationProgressValue(fraction: 0.4, completed: 3, total: 12).fraction == 0.4)
    }

    @Test func phasesDoNotFabricateAudioProgress() {
        var tracker = TranscriptionProgressTracker(startedAt: Date(timeIntervalSince1970: 1000), totalAudioDuration: 600)
        tracker.setPhase(.splitting)
        #expect(tracker.snapshot.overallProgress == nil)
        tracker.setPhase(.transcribing, currentPart: 1, totalParts: 3)
        #expect(tracker.snapshot.overallProgress == nil)
        tracker.completePart(audioDuration: 120, atElapsed: 60)
        #expect(tracker.snapshot.overallProgress == 0.2)
        tracker.setPhase(.saving)
        #expect(tracker.snapshot.overallProgress == 0.2)
        #expect(tracker.snapshot.estimatedRemainingTime == nil)
    }
}

#if DEBUG
@MainActor private final class ObservedOperationFixtureProvider: TranscriptionProvider {
    let displayName = "Observed offline fixture"
    let isMock = true
    var observe: (() -> Void)?
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, status: { _ in })
    }
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress,
                    status: @escaping TranscriptionStatusReporter) async throws -> Transcript {
        try await OperationFixtureTranscriptionProvider(partDelay: .zero).transcribe(audioURL: audioURL,
            progress: progress, status: { [self] update in status(update); observe?() })
    }
}
#endif
