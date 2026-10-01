import Foundation
import SwiftData
@testable import AudioNotes

@MainActor
func sampleTranscript() -> Transcript {
    let transcript = Transcript(languageCode: "en")
    transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 0.8,
                                             text: "Let's review the recording.", speaker: "Speaker 1")]
    return transcript
}

extension TestWorkspace {
    @MainActor
    func makeRecording(in context: ModelContext) async throws -> Recording {
        let audio = try await AudioImportService(storage: storage).importFile(at: makeAudio())
        let recording = Recording(id: audio.id, title: audio.title, audioFileName: audio.fileName,
                                  originalFileName: audio.originalFileName, duration: audio.duration)
        context.insert(recording)
        try context.save()
        return recording
    }
}

@MainActor
struct ClosureTranscriptionProvider: TranscriptionProvider {
    let displayName = "Test provider"
    let operation: @MainActor (URL, TranscriptionProgress) async throws -> Transcript

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        try await operation(audioURL, progress)
    }
}

/// Intentionally ignores cancellation, to verify late progress/results are discarded.
@MainActor
final class SuspendedTranscriptionProvider: TranscriptionProvider {
    let displayName = "Suspended test provider"
    private(set) var callbacks: [TranscriptionProgress] = []
    private var results: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        await withCheckedContinuation { continuation in
            callbacks.append(progress)
            results.append(continuation)
            progress(0.1)
            let ready = waiters.filter { $0.0 <= results.count }
            waiters.removeAll { $0.0 <= results.count }
            for (_, waiter) in ready { waiter.resume() }
        }
        return sampleTranscript()
    }

    func waitForCalls(_ count: Int) async {
        if results.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func finishCall(_ index: Int) {
        results[index].resume()
    }
}
