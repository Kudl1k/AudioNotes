#if DEBUG && os(iOS)
import AVFoundation
import Foundation
import SwiftData

/// Explicit offline review only: in-memory database and the existing temporary fixture root.
@MainActor
enum IOSAudioRecordingFixtures {
    static func prepare(context: ModelContext) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--performance-fixtures"),
              ProcessInfo.processInfo.arguments.contains("--ios-audio-review"),
              try context.fetchCount(FetchDescriptor<Recording>()) == 0 else { return }
        let storage = LibraryStorage()
        let url = storage.recordingURL(fileName: "ios-review.wav")
        try await Task.detached {
            try FileManager.default.createDirectory(at: storage.recordingsURL, withIntermediateDirectories: true)
            let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
            buffer.frameLength = 8_000
            for index in 0..<8_000 { buffer.floatChannelData![0][index] = 0 }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<1_800 {
                try Task.checkCancellation()
                try file.write(from: buffer)
            }
        }.value
        try Task.checkCancellation()
        let recording = Recording(title: "M16 Transcript Review", audioFileName: url.lastPathComponent,
            originalFileName: "Synthetic audio · offline review.wav", duration: 1_800)
        let transcript = Transcript(languageCode: "cs", sourceName: "Synthetic 6,000-segment fixture", isMock: true)
        transcript.segments = (0..<6_000).map { index in
            TranscriptSegment(position: index, startTime: Double(index) * 0.3, endTime: Double(index + 1) * 0.3,
                text: "Úsek \(index + 1): Příliš žluťoučký kůň. This is synthetic transcript text for scrolling and timestamp navigation.",
                speaker: index.isMultiple(of: 2) ? "Speaker A" : "Speaker B")
        }
        recording.transcript = transcript
        recording.summary = Summary(overview: "## Přehled\n\nSynthetic **Markdown** with [an example link](https://example.com).\n\n1. První bod\n2. Druhý bod\n\n```swift\nlet greeting = \"Ahoj\"\n```",
            keyPoints: [KeyPoint(text: "Český Unicode a nativní seznamy")],
            actionItems: [ActionItem(text: "Review the native player", assignee: "Test fixture")],
            title: "Offline review summary")
        recording.summaryHistory = [Summary(overview: "Earlier synthetic summary version", createdAt: Date(timeIntervalSince1970: 0))]
        context.insert(recording)
        SourceCompatibilityMigration().ensurePrimaryAudio(for: recording, context: context)
        try context.save()
    }
}
#endif
