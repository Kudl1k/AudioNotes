import Foundation

extension HierarchicalSummaryGenerator {
    /// Same logical operation/tracker as audio hierarchy. Intermediates never enter SwiftData.
    func generate(context: SourceSummaryContext, configuration: SummaryConfiguration, provider: any LLMProvider,
                  progress: @MainActor (String) -> Void = { _ in }) async throws -> HierarchicalSummaryResult {
        guard !context.chunks.isEmpty else { throw LLMError.transcriptEmpty }
        let limit = min(singlePassLimitTokens, provider.inputCapabilities.contextWindowTokens - min(8000, provider.inputCapabilities.contextWindowTokens / 2) - context.images.count * provider.inputCapabilities.approximateTokensPerImage)
        guard limit >= 2000 else { throw LLMError.contextTooLarge(approximateTokens: context.approximateTokens) }
        if context.approximateTokens <= limit {
            let summary = try await provider.generateSourceSummary(context: context, configuration: configuration)
            return .init(summary: summary, chunkCount: 1)
        }
        var groups: [SourceSummaryContext] = []
        var current: [SourceChunk] = []
        for chunk in context.chunks {
            let proposed = SourceSummaryContext(chunks: current + [chunk])
            if !current.isEmpty && proposed.approximateTokens > limit {
                groups.append(.init(chunks: current)); current = []
            }
            current.append(chunk)
        }
        if !current.isEmpty { groups.append(.init(chunks: current)) }
        // An image appears once in its source pass, never on every synthesis request.
        for image in context.images {
            if let index = groups.firstIndex(where: { $0.chunks.contains(where: { $0.sourceID == image.sourceID }) }) {
                groups[index].images.append(image)
                if !groups[index].chunks.contains(where: { $0.id == image.chunkID }),
                   let anchor = context.chunks.first(where: { $0.id == image.chunkID }) {
                    groups[index].chunks.append(anchor)
                }
            }
        }
        let initialCount = groups.count
        var pass = 0
        while true {
            try Task.checkCancellation()
            pass += 1
            var notes: [SourceSummaryContext] = []
            for (index, group) in groups.enumerated() {
                progress("Summarizing source section \(index + 1) of \(groups.count) (pass \(pass))…")
                var intermediate = configuration
                intermediate.outputLength = .concise
                var settings = intermediate.generationSettings ?? LLMGenerationSettings()
                settings.outputLength = .concise
                settings.maxOutputTokens = min(settings.maxOutputTokens ?? 1200, 1200)
                intermediate.generationSettings = settings
                let summary = try await provider.generateSourceSummary(context: group, configuration: intermediate)
                let supported = Set(summary.sourceReferences.map(\.chunkID))
                let anchors = group.chunks.filter { supported.contains($0.id) }.map { chunk in
                    SourceChunk(id: chunk.id, sourceID: chunk.sourceID, sourceName: chunk.sourceName, sourceType: chunk.sourceType,
                        text: String(chunk.text.prefix(200)), locator: chunk.locator, origin: chunk.origin)
                }
                notes.append(.init(chunks: anchors, intermediateNotes: [Self.render(summary)]))
            }
            var next: [SourceSummaryContext] = []
            var combined = SourceSummaryContext(chunks: [])
            for note in notes {
                let proposed = SourceSummaryContext(chunks: combined.chunks + note.chunks,
                    intermediateNotes: combined.intermediateNotes + note.intermediateNotes)
                if !combined.intermediateNotes.isEmpty && proposed.approximateTokens > limit {
                    next.append(combined); combined = note
                } else { combined = proposed }
            }
            if !combined.intermediateNotes.isEmpty { next.append(combined) }
            if next.count == 1, let finalContext = next.first {
                progress("Creating final multi-source summary…")
                let final = try await provider.generateSourceSummary(context: finalContext, configuration: configuration)
                // Resolve again against full originals so excerpts are authoritative, not derivative notes.
                final.sourceReferences = SourceReferenceResolver().resolve(chunkIDs: final.sourceReferences.map { $0.chunkID.uuidString }, against: context.chunks)
                progress("")
                return .init(summary: final, chunkCount: initialCount)
            }
            guard next.count < groups.count, pass < 12 else { throw LLMError.contextTooLarge(approximateTokens: context.approximateTokens) }
            groups = next
        }
    }
}
