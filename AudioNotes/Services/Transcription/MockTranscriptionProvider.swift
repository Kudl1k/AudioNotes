import AVFoundation
import Foundation

/// Deterministic sample text, not speech recognition. Reads only audio metadata.
struct MockTranscriptionProvider: TranscriptionProvider {
    let displayName = "Mock transcription"
    let isMock = true
    let stepDelay: Duration

    init(stepDelay: Duration = .milliseconds(400)) {
        self.stepDelay = stepDelay
    }

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        try Task.checkCancellation()
        guard audioURL.isFileURL, FileManager.default.isReadableFile(atPath: audioURL.path) else {
            throw TranscriptionError.audioUnavailable
        }
        progress(nil)
        let asset = AVURLAsset(url: audioURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        guard !tracks.isEmpty, duration.isFinite, duration > 0 else {
            throw TranscriptionError.invalidAudio
        }
        try Task.checkCancellation()
        progress(0)
        for step in 1...5 {
            try await Task.sleep(for: stepDelay)
            try Task.checkCancellation()
            progress(Double(step) / 5)
        }

        let transcript = Transcript(languageCode: "en", sourceName: displayName, isMock: true)
        let lines: [(String, String)] = [
            ("Speaker 1", "Thanks for joining. Let's review what we learned from the first round of interviews."),
            ("Speaker 2", "The main request was a simpler way to find the important moments in a recording."),
            ("Speaker 1", "We'll start with a clear transcript and let people jump directly to each timestamp."),
            ("Speaker 2", "I'll prepare a small set of sample recordings so we can test the flow together."),
            ("Speaker 1", "Great. Let's review the results on Friday and agree on the next steps.")
        ]
        // Scale sample timestamps to the actual file so every timestamp is seekable,
        // including recordings shorter than the sample conversation would take.
        let interval = duration / Double(lines.count)
        transcript.segments = lines.enumerated().map { index, line in
            TranscriptSegment(position: index, startTime: Double(index) * interval,
                              endTime: Double(index + 1) * interval, text: line.1, speaker: line.0)
        }
        try Task.checkCancellation()
        return transcript
    }
}
