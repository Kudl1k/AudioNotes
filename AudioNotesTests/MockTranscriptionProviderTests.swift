import Foundation
import Testing
@testable import AudioNotes

@MainActor
struct MockTranscriptionProviderTests {
    @Test func returnsStructuredSampleAndReportsProgress() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let provider = MockTranscriptionProvider(stepDelay: .zero)
        var updates: [Double?] = []
        let transcript = try await provider.transcribe(audioURL: workspace.makeAudio()) { updates.append($0) }
        #expect(transcript.isMock)
        #expect(transcript.sourceName == provider.displayName)
        #expect(transcript.languageCode == "en")
        #expect(transcript.modelContext == nil)
        #expect(transcript.segments.count == 5)
        #expect(updates == [nil, 0, 0.2, 0.4, 0.6, 0.8, 1])
        #expect(transcript.orderedSegments.map(\.position) == [0, 1, 2, 3, 4])
        for segment in transcript.segments {
            #expect(segment.startTime >= 0)
            #expect(segment.endTime > segment.startTime)
            #expect(segment.endTime <= 1.001)
            #expect(!segment.text.isEmpty)
            #expect(segment.speaker != nil)
        }
    }

    @Test func rejectsMissingAudio() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let provider = MockTranscriptionProvider(stepDelay: .zero)
        await #expect(throws: TranscriptionError.self) {
            _ = try await provider.transcribe(audioURL: workspace.root.appending(path: "missing.wav")) { _ in }
        }
    }

    @Test func rejectsCorruptAudio() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let url = workspace.root.appending(path: "broken.wav")
        try Data("broken".utf8).write(to: url)
        await #expect(throws: (any Error).self) {
            _ = try await MockTranscriptionProvider(stepDelay: .zero).transcribe(audioURL: url) { _ in }
        }
    }

    @Test func cancellationInterruptsSimulatedWork() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let url = try workspace.makeAudio()
        var updates: [Double?] = []
        let task = Task {
            _ = try await MockTranscriptionProvider(stepDelay: .seconds(30)).transcribe(audioURL: url) { progress in
                updates.append(progress)
                if progress == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(updates == [nil, 0])
    }
}
