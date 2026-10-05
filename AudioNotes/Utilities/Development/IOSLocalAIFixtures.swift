#if DEBUG && os(iOS)
import Foundation

/// Explicit, offline runtime doubles for isolated Local AI visual review only.
actor IOSLocalLanguageFixture: LocalLLMRunning {
    func stream(_ request: LocalLLMRequest) throws -> AsyncThrowingStream<LocalLLMEvent, Error> {
        AsyncThrowingStream { continuation in
            if case .chat = request.kind {
                continuation.yield(.answerSnapshot("## On-device answer\n\nThis answer uses the selected local evidence."))
                continuation.yield(.completedJSON("{\"answer\":\"## On-device answer\\n\\nThis answer uses the selected local evidence.\",\"referenceSegmentIDs\":[\"S1\",\"S2\"]}"))
            } else {
                continuation.yield(.completedJSON("{\"title\":\"On-device summary\",\"overview\":\"Synthetic local model review.\",\"keyPoints\":[],\"decisions\":[],\"actionItems\":[],\"openQuestions\":[],\"importantQuotes\":[],\"additionalSections\":[],\"referenceChunkIDs\":[]}"))
            }
            continuation.finish()
        }
    }
}

@MainActor struct IOSLocalTranscriptionFixture: TranscriptionProvider {
    let displayName = "On Device"
    let providerID: String? = "localWhisper"
    let modelID: String? = "openai_whisper-tiny"
    let modelDisplayName: String? = "Whisper Tiny"
    let executionLocation: ProviderExecutionLocation = .local
    let billingKind: BillingKind = .local
    var capabilities: TranscriptionProviderCapabilities {
        .init(maxDirectUploadSize: nil, maxProviderFileUploadSize: nil, supportsProviderFileUpload: false,
              supportsTimestamps: true, supportsDiarization: false, maximumDuration: nil, requiresChunking: false)
    }
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        try Task.checkCancellation()
        let transcript = Transcript(languageCode: "en", sourceName: "On Device · Whisper Tiny (review fixture)")
        transcript.segments = [.init(position: 0, startTime: 0, endTime: 10, text: "Synthetic local transcription fixture.")]
        progress(1)
        return transcript
    }
}
#endif
