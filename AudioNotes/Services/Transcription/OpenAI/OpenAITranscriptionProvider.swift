import Foundation

struct OpenAITranscriptionProvider: TranscriptionProvider {
    let configuration: OpenAITranscriptionConfiguration
    let credentials: any CredentialStoring
    let client: OpenAITranscriptionClient
    let splitter: any OpenAIAudioPreparing

    init(
        configuration: OpenAITranscriptionConfiguration,
        credentials: any CredentialStoring,
        client: OpenAITranscriptionClient = OpenAITranscriptionClient(),
        splitter: any OpenAIAudioPreparing = OpenAIAudioSplitter()
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.client = client
        self.splitter = splitter
    }

    var providerID: String? { "openAI" }
    var modelID: String? { configuration.model.rawValue }
    var capabilities: TranscriptionProviderCapabilities {
        .init(maxDirectUploadSize: Int64(OpenAIAudioUpload.maximumFileBytes), maxProviderFileUploadSize: nil, supportsProviderFileUpload: false,
              supportsTimestamps: configuration.model.supportsSegmentTimestamps, supportsDiarization: false,
              maximumDuration: nil, requiresChunking: true)
    }
    var authenticationMethod: ProviderAuthenticationMethod? { .apiKey }

    var displayName: String { "OpenAI · \(configuration.model.rawValue)" }

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, status: { _ in })
    }

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress,
                    status: @escaping TranscriptionStatusReporter) async throws -> Transcript {
        try await transcribe(audioURL: audioURL, progress: progress, status: status, usage: { _ in })
    }

    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress,
                    status: @escaping TranscriptionStatusReporter,
                    usage: @escaping @MainActor (TranscriptionRequestEvent) -> Void) async throws -> Transcript {
        try Task.checkCancellation()
        progress(nil) // OpenAI does not report progress within an individual request.
        guard let storedKey = try await credentials.apiKey(for: .openAI) else {
            throw OpenAITranscriptionError.missingAPIKey
        }
        let key = try APIKeyInput.normalized(storedKey)
        try Task.checkCancellation()
        status(TranscriptionStatus(phase: .preparing, currentPart: nil, totalParts: nil, completedParts: 0,
                                   processedAudioDuration: 0, totalAudioDuration: 0))
        var sourceURL = audioURL
        sourceURL.removeAllCachedResourceValues()
        let sourceSize = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let sourceSize, sourceSize > OpenAIAudioUpload.maximumFileBytes {
            status(TranscriptionStatus(phase: .splitting, currentPart: nil, totalParts: nil, completedParts: 0,
                                       processedAudioDuration: 0, totalAudioDuration: 0))
        }
        let split = try await splitter.prepare(fileURL: audioURL)
        defer {
            if let directory = split.directory { try? FileManager.default.removeItem(at: directory) }
        }
        if split.wasSplit {
            status(TranscriptionStatus(phase: .splitting, currentPart: nil, totalParts: split.parts.count,
                                       completedParts: 0, processedAudioDuration: 0, totalAudioDuration: split.totalDuration))
        }

        let merged = Transcript(sourceName: displayName)
        var completedAudio: TimeInterval = 0
        for (index, part) in split.parts.enumerated() {
            try Task.checkCancellation()
            status(TranscriptionStatus(phase: .transcribing, currentPart: index + 1, totalParts: split.parts.count,
                                       completedParts: index, processedAudioDuration: completedAudio,
                                       totalAudioDuration: split.totalDuration))
            let requestID = UUID()
            usage(.began(requestID))
            let response: OpenAITranscriptionResponse
            do {
                response = try await client.transcribe(fileURL: part.url, apiKey: key, configuration: configuration)
                let reported = response.duration.flatMap { $0.isFinite && $0 >= 0 ? Decimal(string: String($0)) : nil }
                usage(.finished(requestID, TranscriptionUsage(recordingDuration: Decimal(string: String(split.totalDuration)),
                    processedDuration: Decimal(string: String(part.duration)), providerReportedDuration: reported), true))
            } catch {
                usage(.finished(requestID, nil, false))
                throw error
            }
            try Task.checkCancellation()
            let partTranscript = try response.makeTranscript(modelName: configuration.model.rawValue,
                                                             audioDuration: part.duration)
            if index == 0 { merged.languageCode = partTranscript.languageCode }
            for segment in partTranscript.orderedSegments {
                guard segment.startTime < part.duration else { continue }
                let startTime = min(part.duration, max(0, segment.startTime))
                let endTime = min(part.duration, max(startTime, segment.endTime))
                merged.segments.append(TranscriptSegment(position: merged.segments.count,
                    startTime: startTime + part.startTime, endTime: endTime + part.startTime,
                    text: segment.text, speaker: segment.speaker))
            }
            completedAudio += part.duration
            if split.wasSplit {
                let fraction = min(1, completedAudio / split.totalDuration)
                progress(fraction)
            }
            status(TranscriptionStatus(phase: .transcribing, currentPart: index + 1, totalParts: split.parts.count,
                                      completedParts: index + 1, processedAudioDuration: completedAudio,
                                      totalAudioDuration: split.totalDuration))
        }
        try Task.checkCancellation()
        status(TranscriptionStatus(phase: .merging, currentPart: nil, totalParts: split.parts.count,
                                   completedParts: split.parts.count, processedAudioDuration: completedAudio,
                                   totalAudioDuration: split.totalDuration))
        guard !merged.segments.isEmpty else { throw OpenAITranscriptionError.noSpeech }
        return merged
    }
}
