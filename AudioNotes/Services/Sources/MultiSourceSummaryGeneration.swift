import Foundation

extension HierarchicalSummaryGenerator {
    /// Same logical operation/tracker as audio hierarchy. Intermediates never enter SwiftData.
    func generate(context: SourceSummaryContext, configuration: SummaryConfiguration, provider: any LLMProvider,
                  progress: @MainActor (String) -> Void = { _ in }) async throws -> HierarchicalSummaryResult {
        guard !context.chunks.isEmpty else { throw LLMError.transcriptEmpty }
        try await provider.prepareForGeneration()
        let limit = min(singlePassLimitTokens, provider.inputCapabilities.contextWindowTokens - min(8000, provider.inputCapabilities.contextWindowTokens / 2) - context.images.count * provider.inputCapabilities.approximateTokensPerImage)
        guard limit > 0 else { throw LLMError.contextTooLarge(approximateTokens: context.approximateTokens) }
        if context.approximateTokens <= limit, try await provider.summaryRequestFits(context: context, configuration: configuration) {
            let summary = try await provider.generateSourceSummary(context: context, configuration: configuration)
            return .init(summary: summary, chunkCount: 1)
        }
        let partitions = try await fittingChunks(context.chunks, configuration: configuration, provider: provider, limit: limit)
        var groups: [SourceSummaryContext] = []
        var current: [SourceChunk] = []
        for chunk in partitions {
            let proposed = SourceSummaryContext(chunks: current + [chunk])
            let requestFits = try await provider.summaryRequestFits(context: proposed, configuration: configuration)
            let fits = proposed.approximateTokens <= limit && requestFits
            if !current.isEmpty && !fits {
                groups.append(.init(chunks: current)); current = []
            }
            // Repeated fragments share the authoritative ID. Keep them in separate
            // requests so a model never sees ambiguous duplicate citation IDs.
            if current.contains(where: { $0.id == chunk.id }) {
                groups.append(.init(chunks: current)); current = []
            }
            current.append(chunk)
        }
        if !current.isEmpty { groups.append(.init(chunks: current)) }
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
                guard try await provider.summaryRequestFits(context: group, configuration: intermediate) else {
                    throw LLMError.contextTooLarge(approximateTokens: group.approximateTokens)
                }
                let summary = try await provider.generateSourceSummary(context: group, configuration: intermediate)
                let supported = Set(summary.sourceReferences.map(\.chunkID))
                // Evidence anchors are a bounded citation index for derivative notes,
                // not a second copy of the source text.
                var seenAnchorIDs = Set<UUID>()
                let anchors = group.chunks.filter { supported.contains($0.id) && seenAnchorIDs.insert($0.id).inserted }.prefix(8).map { chunk in
                    SourceChunk(id: chunk.id, sourceID: chunk.sourceID, sourceName: chunk.sourceName, sourceType: chunk.sourceType,
                        text: String(chunk.text.prefix(80)), locator: chunk.locator, origin: chunk.origin)
                }
                var note = SourceSummaryContext(chunks: anchors, intermediateNotes: [Self.render(summary)])
                while !note.chunks.isEmpty {
                    if try await provider.summaryRequestFits(context: note, configuration: configuration) { break }
                    note.chunks.removeLast()
                }
                notes.append(note)
            }
            var next: [SourceSummaryContext] = []
            var combined = SourceSummaryContext(chunks: [])
            for note in notes {
                var seenIDs = Set<UUID>()
                let anchors = (combined.chunks + note.chunks).filter { seenIDs.insert($0.id).inserted }
                let proposed = SourceSummaryContext(chunks: anchors,
                    intermediateNotes: combined.intermediateNotes + note.intermediateNotes)
                guard try await provider.summaryRequestFits(context: note, configuration: configuration) else {
                    throw LLMError.contextTooLarge(approximateTokens: note.approximateTokens)
                }
                let requestFits = try await provider.summaryRequestFits(context: proposed, configuration: configuration)
                let fits = proposed.approximateTokens <= limit && requestFits
                if !combined.intermediateNotes.isEmpty && !fits {
                    next.append(combined); combined = note
                } else { combined = proposed }
            }
            if !combined.intermediateNotes.isEmpty { next.append(combined) }
            if next.count == 1, let finalContext = next.first,
               try await provider.summaryRequestFits(context: finalContext, configuration: configuration) {
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

    /// Fragments are request-only; IDs and original locators remain authoritative.
    private func fittingChunks(_ chunks: [SourceChunk], configuration: SummaryConfiguration,
                               provider: any LLMProvider, limit: Int) async throws -> [SourceChunk] {
        var result: [SourceChunk] = []
        for chunk in chunks {
            try Task.checkCancellation()
            let context = SourceSummaryContext(chunks: [chunk])
            if context.approximateTokens <= limit,
               try await provider.summaryRequestFits(context: context, configuration: configuration) {
                result.append(chunk)
            } else {
                guard chunk.text.count > 1 else { throw LLMError.contextTooLarge(approximateTokens: context.approximateTokens) }
                let middle = chunk.text.index(chunk.text.startIndex, offsetBy: chunk.text.count / 2)
                let fragments = [String(chunk.text[..<middle]), String(chunk.text[middle...])].map { text in
                    SourceChunk(id: chunk.id, sourceID: chunk.sourceID, sourceName: chunk.sourceName,
                        sourceType: chunk.sourceType, text: text, locator: chunk.locator, origin: chunk.origin,
                        referenceAlias: chunk.referenceAlias)
                }
                result += try await fittingChunks(fragments, configuration: configuration, provider: provider, limit: limit)
            }
        }
        return result
    }

}
