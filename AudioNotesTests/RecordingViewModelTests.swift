import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RecordingViewModelTests {
    @Test func completesAllPhasesAndPersistsManagedFileResult() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        var states: [TranscriptionState] = []
        var model: RecordingViewModel!
        let provider = ClosureTranscriptionProvider { url, progress in
            #expect(url == workspace.storage.recordingURL(fileName: recording.audioFileName))
            states.append(model.state)
            progress(0.4)
            #expect(model.progress == 0.4)
            progress(nil)
            #expect(model.progress == nil)
            progress(2)
            #expect(model.progress == 1)
            progress(.nan)
            #expect(model.progress == nil)
            return sampleTranscript()
        }
        model = RecordingViewModel(recording: recording, provider: provider, storage: workspace.storage)
        #expect(model.state == .idle)
        let repository = SwiftDataTranscriptRepository(context: context) { context in
            states.append(model.state)
            #expect(model.progress == nil)
            try context.save()
        }
        let task = try #require(model.startTranscription(using: repository))
        states.append(model.state)
        #expect(model.progressSnapshot?.phase == .preparing)
        #expect(model.progressSnapshot?.startedAt != nil)
        #expect(model.startTranscription(using: repository) == nil)
        await task.value
        states.append(model.state)
        #expect(states == [.preparing, .transcribing, .saving, .completed])
        #expect(model.progress == 1)
        #expect(recording.transcript?.sourceName == "Test provider")
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSegment>()) == 1)
        #expect(!model.canTranscribe)
        #expect(model.startTranscription(using: repository) == nil)
    }

    @Test func cancellationAndRetryIgnoreOldProgressAndResults() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        let provider = SuspendedTranscriptionProvider()
        let model = RecordingViewModel(recording: recording, provider: provider, storage: workspace.storage)
        let repository = SwiftDataTranscriptRepository(context: context)
        let first = try #require(model.startTranscription(using: repository))
        await provider.waitForCalls(1)
        #expect(model.state == .transcribing)
        model.cancelTranscription()
        #expect(model.state == .cancelled)
        #expect(model.progress == nil)
        #expect(recording.transcript == nil)

        let second = try #require(model.startTranscription(using: repository))
        await provider.waitForCalls(2)
        provider.callbacks[0](0.9)
        #expect(model.progress == 0.1)
        provider.finishCall(0)
        await first.value
        #expect(model.state == .transcribing)
        #expect(recording.transcript == nil)
        provider.finishCall(1)
        await second.value
        #expect(model.state == .completed)
        #expect(try context.fetchCount(FetchDescriptor<Transcript>()) == 1)
    }

    @Test func cancellingDuringPreparationNeverCallsProvider() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        var calls = 0
        let model = RecordingViewModel(recording: recording, provider: ClosureTranscriptionProvider { _, _ in
            calls += 1
            return sampleTranscript()
        }, storage: workspace.storage)
        let task = try #require(model.startTranscription(using: SwiftDataTranscriptRepository(context: context)))
        model.cancelTranscription()
        await task.value
        #expect(calls == 0)
        #expect(model.state == .cancelled)
        #expect(recording.transcript == nil)
    }

    @Test func providerFailureCanBeRetried() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        var calls = 0
        let provider = ClosureTranscriptionProvider { _, _ in
            calls += 1
            if calls == 1 { throw TranscriptionError.invalidAudio }
            return sampleTranscript()
        }
        let model = RecordingViewModel(recording: recording, provider: provider, storage: workspace.storage)
        let repository = SwiftDataTranscriptRepository(context: context)
        await model.startTranscription(using: repository)?.value
        #expect(model.state == .failed(message: TranscriptionError.invalidAudio.localizedDescription))
        #expect(model.progress == nil)
        #expect(recording.transcript == nil)
        #expect(model.canTranscribe)
        await model.startTranscription(using: repository)?.value
        #expect(model.state == .completed)
    }

    @Test func saveFailureClearsGraphAndReportsError() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        let model = RecordingViewModel(recording: recording,
                                       provider: MockTranscriptionProvider(stepDelay: .zero), storage: workspace.storage)
        let repository = SwiftDataTranscriptRepository(context: context) { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }
        await model.startTranscription(using: repository)?.value
        if case .failed = model.state {} else { Issue.record("Expected a persistence failure") }
        #expect(recording.transcript == nil)
        #expect(model.progress == nil)
        // Later saves must not resurrect an incomplete graph.
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Transcript>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TranscriptSegment>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 1)
    }

    @Test func missingManagedAudioFailsPreparation() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let recording = Recording(title: "Missing", audioFileName: "missing.wav", originalFileName: "missing.wav", duration: 1)
        let model = RecordingViewModel(recording: recording, storage: workspace.storage)
        await model.startTranscription(using: SwiftDataTranscriptRepository(context: container.mainContext))?.value
        #expect(model.state == .failed(message: TranscriptionError.audioUnavailable.localizedDescription))
        #expect(recording.transcript == nil)
    }

    @Test func persistedTranscriptStartsCompleted() {
        let recording = Recording(title: "Existing", audioFileName: "audio.wav", originalFileName: "audio.wav", duration: 1)
        recording.transcript = sampleTranscript()
        let model = RecordingViewModel(recording: recording)
        #expect(model.state == .completed)
        #expect(!model.canTranscribe)
    }

    @Test func regenerationKeepsCurrentUntilSuccessAndLinksGenerationHistory() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        let repository = SwiftDataTranscriptRepository(context: context)
        let first = sampleTranscript()
        try repository.save(first, for: recording)
        let provider = SuspendedTranscriptionProvider()
        let model = RecordingViewModel(recording: recording, provider: provider, storage: workspace.storage)
        #expect(model.canRegenerate)
        let task = try #require(model.startTranscription(using: repository, replacingExisting: true))
        await provider.waitForCalls(1)
        #expect(recording.transcript?.id == first.id)
        #expect(recording.transcriptHistory.isEmpty)
        #expect(!model.canRegenerate)
        provider.finishCall(0)
        await task.value
        #expect(recording.transcript?.id != first.id)
        #expect(recording.transcriptHistory.map(\.id) == [first.id])
        #expect(recording.transcript?.generationID == recording.generationRecords.first?.id)
    }

    @Test func cancelledOrFailedRegenerationRetainsCurrentTranscript() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try await workspace.makeRecording(in: context)
        let repository = SwiftDataTranscriptRepository(context: context)
        let first = sampleTranscript()
        try repository.save(first, for: recording)
        let provider = SuspendedTranscriptionProvider()
        let model = RecordingViewModel(recording: recording, provider: provider, storage: workspace.storage)
        let task = try #require(model.startTranscription(using: repository, replacingExisting: true))
        await provider.waitForCalls(1)
        model.cancelTranscription()
        provider.finishCall(0)
        await task.value
        #expect(recording.transcript?.id == first.id)
        #expect(recording.transcriptHistory.isEmpty)
        let failingModel = RecordingViewModel(recording: recording, provider: ClosureTranscriptionProvider { _, _ in
            throw TranscriptionError.invalidAudio
        }, storage: workspace.storage)
        await failingModel.startTranscription(using: repository, replacingExisting: true)?.value
        #expect(recording.transcript?.id == first.id)
        #expect(recording.transcriptHistory.isEmpty)
        #expect(failingModel.canRegenerate)
    }
}
