import Foundation

struct LocalWhisperSegment: Sendable { let start: TimeInterval; let end: TimeInterval; let text: String }
struct LocalWhisperResult: Sendable { let language: String?; let segments: [LocalWhisperSegment] }
typealias LocalWhisperStatusReporter = @Sendable (TimeInterval, TimeInterval) async -> Void

protocol LocalWhisperRunning: Sendable {
    func transcribe(audioURL: URL, modelFolder: URL, language: String?,
                    status: @escaping LocalWhisperStatusReporter) async throws -> LocalWhisperResult
}

#if !os(macOS)
struct UnavailableWhisperRuntime: LocalWhisperRunning {
    func transcribe(audioURL: URL, modelFolder: URL, language: String?,
                    status: @escaping LocalWhisperStatusReporter) async throws -> LocalWhisperResult {
        throw LocalAIError.unsupportedHardware
    }
}

enum LocalWhisperRuntimeCapabilities {
    static var languageCodes: Set<String> { [] }
    static var isSupported: Bool { false }
}
#endif

@MainActor final class LocalWhisperTranscriptionProvider: TranscriptionProvider {
    let displayName = "Local Whisper"
    let providerID: String? = "localWhisper"
    let billingKind: BillingKind = .local
    let executionLocation: ProviderExecutionLocation = .local
    var modelID: String? { model.id }
    var modelDisplayName: String? { model.title }
    let model: WhisperModelDescriptor
    let language: String?
    let runtime: any LocalWhisperRunning
    let store: WhisperModelStore

#if os(macOS)
    init(model: WhisperModelDescriptor, language: String?, runtime: any LocalWhisperRunning = WhisperKitRuntime(), store: WhisperModelStore) {
        self.model = model; self.language = language; self.runtime = runtime; self.store = store
    }
#else
    init(model: WhisperModelDescriptor, language: String?, runtime: any LocalWhisperRunning = UnavailableWhisperRuntime(), store: WhisperModelStore) {
        self.model = model; self.language = language; self.runtime = runtime; self.store = store
    }
#endif

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, status: { _ in })
    }
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress, status: @escaping TranscriptionStatusReporter) async throws -> Transcript {
        try Task.checkCancellation()
        try await store.acquire()
        do {
            guard await store.isReady(model) else { throw LocalAIError.missingModel(model.title) }
            let folder = await store.folder(model)
            let result = try await runtime.transcribe(audioURL: audioURL, modelFolder: folder, language: language) { processed, total in
                await status(.init(phase: .transcribing, currentPart: nil, totalParts: nil, completedParts: 0,
                    processedAudioDuration: processed, totalAudioDuration: total))
                await progress(total > 0 ? min(1, processed / total) : nil)
            }
            try Task.checkCancellation()
            let transcript = try Self.makeTranscript(result, model: model.title)
            await store.release()
            return transcript
        } catch { await store.release(); throw error }
    }
    static func makeTranscript(_ result: LocalWhisperResult, model: String) throws -> Transcript {
        let segments = result.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !segments.isEmpty, segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else { throw TranscriptionError.invalidTranscript }
        let transcript = Transcript(languageCode: result.language, sourceName: "Local Whisper · " + model)
        transcript.segments = segments.sorted { $0.start < $1.start }.enumerated().map {
            TranscriptSegment(position: $0.offset, startTime: $0.element.start, endTime: $0.element.end, text: $0.element.text)
        }
        return transcript
    }
}
