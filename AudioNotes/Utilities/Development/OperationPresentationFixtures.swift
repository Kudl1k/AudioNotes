#if DEBUG
import AVFoundation
import Foundation
import SwiftData

/// Explicit offline UI fixtures. Only called from the isolated in-memory scene.
@MainActor enum OperationPresentationFixtures {
    static let recordingID = PerformanceFixtures.id("layout-multipart")
    static let emptyProjectID = PerformanceFixtures.id("layout-empty-project")

    static func prepare(context: ModelContext, storage: LibraryStorage = LibraryStorage()) throws {
        let existing = try context.fetch(FetchDescriptor<Recording>())
        guard !existing.contains(where: { $0.id == recordingID }) else { return }
        let project = try context.fetch(FetchDescriptor<Project>()).first { $0.id == ProjectChatFixtures.projectID }
        context.insert(Project(id: emptyProjectID, name: "Empty Project", createdAt: PerformanceFixtures.epoch))
        for failure in [false, true] {
            let id = failure ? PerformanceFixtures.id("layout-failure") : recordingID
            let fileName = "\(id.uuidString)/fixture\(failure ? "-failure" : "").wav"
            let url = storage.recordingURL(fileName: fileName)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000)!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData?.pointee.initialize(repeating: 0, count: Int(buffer.frameLength))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            let recording = Recording(id: id, title: failure ? "Transcription Failure Fixture" : "Multipart Progress Fixture",
                audioFileName: fileName, originalFileName: "fixture.wav", duration: 12, importedAt: PerformanceFixtures.epoch)
            recording.project = project
            context.insert(recording)
        }
        try context.save()
    }
}

/// Three real mock completions, with measured wall time, exercise the production
/// progress tracker, task ownership, cancellation, persistence and retry paths.
struct OperationFixtureTranscriptionProvider: TranscriptionProvider {
    let displayName = "Offline Multipart Fixture"
    let isMock = true
    var partDelay: Duration = .seconds(3)

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, status: { _ in })
    }

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress,
                    status: @escaping TranscriptionStatusReporter) async throws -> Transcript {
        progress(nil)
        status(.init(phase: .splitting, currentPart: nil, totalParts: nil, completedParts: 0,
            processedAudioDuration: 0, totalAudioDuration: 12))
        try await Task.sleep(for: partDelay)
        let transcript = Transcript(languageCode: "en", sourceName: displayName, isMock: true)
        for part in 1...3 {
            status(.init(phase: .transcribing, currentPart: part, totalParts: 3, completedParts: part - 1,
                processedAudioDuration: Double(part - 1) * 4, totalAudioDuration: 12))
            try await Task.sleep(for: partDelay)
            try Task.checkCancellation()
            if audioURL.lastPathComponent.contains("failure") { throw TranscriptionError.invalidAudio }
            transcript.segments.append(TranscriptSegment(position: part - 1, startTime: Double(part - 1) * 4,
                endTime: Double(part) * 4, text: "Completed offline fixture part \(part)."))
            status(.init(phase: .transcribing, currentPart: part, totalParts: 3, completedParts: part,
                processedAudioDuration: Double(part) * 4, totalAudioDuration: 12))
        }
        return transcript
    }
}
#endif
