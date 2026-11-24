import Foundation

struct LocalWhisperSegment: Codable, Sendable { let start: TimeInterval; let end: TimeInterval; let text: String }
struct LocalWhisperResult: Codable, Sendable { let language: String?; let segments: [LocalWhisperSegment] }
typealias LocalWhisperStatusReporter = @Sendable (TimeInterval, TimeInterval, Bool) async -> Void

protocol LocalWhisperRunning: Sendable {
    func transcribe(audioURL: URL, modelFolder: URL, language: String?,
                    status: @escaping LocalWhisperStatusReporter) async throws -> LocalWhisperResult
}

@MainActor final class LocalWhisperTranscriptionProvider: TranscriptionProvider {
    #if os(iOS)
    let displayName = "On Device"
#else
    let displayName = "Local Whisper"
#endif
    let providerID: String? = "localWhisper"
    let billingKind: BillingKind = .local
    let executionLocation: ProviderExecutionLocation = .local
    var modelID: String? { model.id }
    var modelDisplayName: String? { model.title }
    let model: WhisperModelDescriptor
    let language: String?
    let runtime: any LocalWhisperRunning
    let store: WhisperModelStore
    let coordinator: LocalInferenceCoordinator

    init(model: WhisperModelDescriptor, language: String?, runtime: (any LocalWhisperRunning)? = nil, store: WhisperModelStore, coordinator: LocalInferenceCoordinator? = nil) {
        self.model = model
        self.language = language
        self.runtime = runtime ?? WhisperKitRuntime(modelRevision: model.files.map { $0.sha256 ?? $0.url.absoluteString })
        self.store = store
        self.coordinator = coordinator ?? LocalInferenceCoordinator()
    }
    var capabilities: TranscriptionProviderCapabilities {
        .init(maxDirectUploadSize: nil, maxProviderFileUploadSize: nil, supportsProviderFileUpload: false,
              supportsTimestamps: true, supportsDiarization: false, maximumDuration: nil, requiresChunking: false)
    }

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, status: { _ in })
    }
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress, status: @escaping TranscriptionStatusReporter) async throws -> Transcript {
        try Task.checkCancellation()
        try await coordinator.acquire()
        do { try await store.acquire() }
        catch { await coordinator.release(); throw error }
        do {
            guard await store.isReady(model) else { throw LocalAIError.missingModel(model.title) }
            let folder = await store.folder(model)
            let result = try await runtime.transcribe(audioURL: audioURL, modelFolder: folder, language: language) { processed, total, reused in
                await status(.init(phase: .transcribing, currentPart: nil, totalParts: nil, completedParts: 0,
                    processedAudioDuration: processed, totalAudioDuration: total, reusedPart: reused))
                await progress(total > 0 ? min(1, processed / total) : nil)
            }
            try Task.checkCancellation()
            let transcript = try Self.makeTranscript(result, model: model.title)
            await store.release()
            await coordinator.release()
            return transcript
        } catch {
            await store.release(); await coordinator.release()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if error is LocalAIError || error is TranscriptionError { throw error }
            throw LocalAIError.inference("On-device transcription failed. Retry, download the model again, or explicitly choose another provider.")
        }
    }
    static func makeTranscript(_ result: LocalWhisperResult, model: String) throws -> Transcript {
        let validSegments = result.segments.compactMap { seg -> LocalWhisperSegment? in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard seg.start.isFinite, seg.end.isFinite else { return nil }
            let start = max(0, seg.start)
            let end = max(start, seg.end)
            guard start.isFinite, end.isFinite else { return nil }
            return LocalWhisperSegment(start: start, end: end, text: seg.text)
        }
        guard !validSegments.isEmpty else { throw TranscriptionError.invalidTranscript }
        let transcript = Transcript(languageCode: result.language, sourceName: "Local Whisper · " + model)
        transcript.segments = validSegments.sorted { $0.start < $1.start }.enumerated().map {
            TranscriptSegment(position: $0.offset, startTime: $0.element.start, endTime: $0.element.end, text: $0.element.text)
        }
        return transcript
    }
}
