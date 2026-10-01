import Foundation

struct HierarchicalSummaryResult {
    let summary: Summary
    let chunkCount: Int
}

@MainActor
struct HierarchicalSummaryGenerator {
    var chunker: TranscriptChunker
    var singlePassLimitTokens: Int

    init(chunker: TranscriptChunker = TranscriptChunker(targetCharacters: 28_000, overlapSegments: 2), singlePassLimitTokens: Int = 32_000) {
        self.chunker = chunker
        self.singlePassLimitTokens = singlePassLimitTokens
    }

    func generate(
        transcript: Transcript,
        configuration: SummaryConfiguration,
        provider: any LLMProvider,
        progress: @MainActor (String) -> Void = { _ in }
    ) async throws -> HierarchicalSummaryResult {
        let snapshots = transcript.segmentSnapshots
        let chunks = chunker.chunks(from: snapshots)
        guard !chunks.isEmpty else { throw LLMError.transcriptEmpty }
        let estimatedTokens = chunks.reduce(0) { $0 + $1.approximateTokens }
        if estimatedTokens <= singlePassLimitTokens {
            progress("")
            return HierarchicalSummaryResult(
                summary: try await provider.generateSummary(transcript: transcript, configuration: configuration),
                chunkCount: 1
            )
        }

        var intermediate: [(TranscriptChunk, Summary)] = []
        intermediate.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress("Summarizing section \(index + 1) of \(chunks.count)…")
            let localTranscript = Transcript(languageCode: transcript.languageCode, sourceName: transcript.sourceName, isMock: transcript.isMock)
            localTranscript.segments = chunk.segments.enumerated().map { position, segment in
                TranscriptSegment(id: segment.id, position: position, startTime: segment.startTime, endTime: segment.endTime, text: segment.text, speaker: segment.speaker)
            }
            var intermediateSettings = configuration.generationSettings ?? LLMGenerationSettings()
            intermediateSettings.outputLength = .concise
            if let maximum = intermediateSettings.maxOutputTokens {
                intermediateSettings.maxOutputTokens = min(maximum, 1_200)
            } else {
                intermediateSettings.maxOutputTokens = 1_200
            }
            let intermediateConfiguration = SummaryConfiguration(
                preset: configuration.preset,
                customInstructions: configuration.customInstructions,
                providerID: configuration.providerID,
                modelName: configuration.modelName,
                generationSettings: intermediateSettings,
                outputLength: .concise
            )
            let summary = try await provider.generateSummary(transcript: localTranscript, configuration: intermediateConfiguration)
            intermediate.append((chunk, summary))
        }

        try Task.checkCancellation()
        progress("Creating final summary…")
        let synthesisTranscript = Transcript(languageCode: transcript.languageCode, sourceName: "Intermediate summaries", isMock: transcript.isMock)
        synthesisTranscript.segments = intermediate.enumerated().map { index, pair in
            let (chunk, summary) = pair
            let detail = Self.render(summary)
            return TranscriptSegment(
                position: index,
                startTime: chunk.startTime,
                endTime: max(chunk.startTime, chunk.endTime),
                text: "Section \(index + 1) (\(AudioTime.format(chunk.startTime))–\(AudioTime.format(chunk.endTime))):\n\(detail)"
            )
        }
        let final = try await provider.generateSummary(transcript: synthesisTranscript, configuration: configuration)
        try Task.checkCancellation()
        Self.resolveSummaryTimestamps(in: final, against: snapshots)
        progress("")
        return HierarchicalSummaryResult(summary: final, chunkCount: chunks.count)
    }

    static func render(_ summary: Summary) -> String {
        var lines = [summary.overview]
        if !summary.keyPoints.isEmpty { lines.append("Key points: " + summary.keyPoints.map(\.text).joined(separator: "; ")) }
        if !summary.decisions.isEmpty { lines.append("Decisions: " + summary.decisions.map(\.text).joined(separator: "; ")) }
        if !summary.actionItems.isEmpty { lines.append("Action items: " + summary.actionItems.map(\.text).joined(separator: "; ")) }
        if !summary.openQuestions.isEmpty { lines.append("Open questions: " + summary.openQuestions.map(\.text).joined(separator: "; ")) }
        if !summary.importantQuotes.isEmpty { lines.append("Quotes: " + summary.importantQuotes.map(\.text).joined(separator: "; ")) }
        lines.append(contentsOf: summary.additionalSections.map { "\($0.title): \($0.items.joined(separator: "; "))" })
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Maps model-selected times back to the nearest authoritative original segment start.
    private static func resolveSummaryTimestamps(in summary: Summary, against segments: [TranscriptSegmentSnapshot]) {
        guard !segments.isEmpty else { return }
        func resolved(_ time: TimeInterval?) -> TimeInterval? {
            guard let time else { return nil }
            return segments.min(by: { abs($0.startTime - time) < abs($1.startTime - time) })?.startTime
        }
        summary.decisions = summary.decisions.map { var item = $0; item.timestamp = resolved(item.timestamp); return item }
        summary.actionItems = summary.actionItems.map { var item = $0; item.timestamp = resolved(item.timestamp); return item }
        summary.openQuestions = summary.openQuestions.map { var item = $0; item.timestamp = resolved(item.timestamp); return item }
        summary.importantQuotes = summary.importantQuotes.map { var item = $0; item.timestamp = resolved(item.timestamp); return item }
    }
}
