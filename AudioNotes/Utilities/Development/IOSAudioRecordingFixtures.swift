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
            // Reuse only a complete synthetic file in the isolated fixture root.
            // Rewriting 30 minutes of silence dominated repeated launch captures.
            if let existing = try? AVAudioFile(forReading: url), existing.length == 8_000 * 1_800 { return }
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
        let uxReview = ProcessInfo.processInfo.arguments.contains("--ios-ux-review")
        let transcript = Transcript(languageCode: "cs", sourceName: "Synthetic 6,000-segment fixture", isMock: true)
        transcript.segments = (0..<(uxReview ? 24 : 6_000)).map { index in
            TranscriptSegment(position: index, startTime: Double(index) * 0.3, endTime: Double(index + 1) * 0.3,
                text: "Úsek \(index + 1): Příliš žluťoučký kůň. This is synthetic transcript text for scrolling and timestamp navigation.",
                speaker: index.isMultiple(of: 2) ? "Speaker A" : "Speaker B")
        }
        if ProcessInfo.processInfo.arguments.contains("--ios-review-chat-history") || ProcessInfo.processInfo.arguments.contains("--ios-review-long-chat") {
            let session = ChatSession()
            let count = ProcessInfo.processInfo.arguments.contains("--ios-review-long-chat") ? 250 : 4
            session.messages = (0..<count).map { index in
                ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                    text: index.isMultiple(of: 2) ? "What should I take away from this recording?" : "## Recording notes\n\nThis is an **offline synthetic conversation** for native Markdown and scrolling review.\n\n- Keep the transcript readable.\n- Review playback and the compact composer.\n\nThe original audio remains available through the transcript timestamp.",
                    createdAt: Date(timeIntervalSince1970: Double(index)),
                    references: index.isMultiple(of: 2) ? [] : TranscriptReferenceResolver().resolve(segmentIDs: [transcript.segments[0].id.uuidString], against: transcript.segmentSnapshots))
            }
            recording.chatSessions = [session]
        }
        recording.transcript = transcript
        recording.summary = Summary(overview: "## Přehled\n\nSynthetic **Markdown** with [an example link](https://example.com).\n\n1. První bod\n2. Druhý bod\n\n```swift\nlet greeting = \"Ahoj\"\n```",
            keyPoints: [KeyPoint(text: "Český Unicode a nativní seznamy")],
            actionItems: [ActionItem(text: "Review the native player", assignee: "Test fixture")],
            title: "Offline review summary")
        recording.summaryHistory = [Summary(overview: "Earlier synthetic summary version", createdAt: Date(timeIntervalSince1970: 0))]
        if uxReview {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--ios-review-empty-transcript") { recording.transcript = nil; recording.summary = nil }
            if args.contains("--ios-review-empty-summary") { recording.summary = nil }
            if args.contains("--ios-review-long-title") {
                recording.title = "A very long recording title with readable university meeting context and follow-up decisions for the next semester"
            }
            if args.contains("--ios-review-projects") {
                for name in ["University", "Work", "Meetings", "Personal"] {
                    let title = args.contains("--ios-review-long-project") && name == "University" ? "University research and lectures with a very long project name for accessibility review" : name
                    let project = Project(name: title)
                    context.insert(project)
                    if name == "University" { recording.project = project }
                }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--ios-review-large-library") {
            for index in 0..<400 {
                context.insert(Recording(title: "Offline library recording \(index + 1)", audioFileName: "fixture-\(index).wav", originalFileName: "Synthetic fixture", duration: Double(60 + index)))
            }
        }
        context.insert(recording)
        SourceCompatibilityMigration().ensurePrimaryAudio(for: recording, context: context)
        try context.save()
    }
}
#endif
