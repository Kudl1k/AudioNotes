import Foundation

@MainActor
struct SourceContextPreparation {
    var storage = LibraryStorage()

    func prepareChat(recording: Recording, selectedSourceIDs: Set<UUID>?, history: [LLMChatMessage],
                     provider: any LLMProvider, settings: LLMGenerationSettings, allowImages: Bool) async throws -> ChatContext {
        let snapshot = try await RecordingContextSnapshot.load(recording: recording, selectedSourceIDs: selectedSourceIDs)
        let query = history.last(where: { $0.role == .user })?.content ?? ""
        let capabilities = provider.inputCapabilities
        let historyTokens = history.reduce(0) { $0 + TranscriptTokenEstimator.estimate($1.content) }
        let reserve = min(settings.maxOutputTokens ?? 8000, capabilities.contextWindowTokens / 4)
        let maximum = RetrievalBudget(contextWindow: capabilities.contextWindowTokens, outputReserve: reserve,
            systemTokens: min(4000, capabilities.contextWindowTokens / 4), historyTokens: historyTokens,
            imageTokens: allowImages && capabilities.supportsImageInput ? 2 * capabilities.approximateTokensPerImage : 0).availableTokens
        guard maximum >= 1500 else { throw LLMError.contextTooLarge(approximateTokens: historyTokens) }
        let retrieved = await Task.detached {
            RecordingContextRetriever().retrieve(query: query, snapshot: snapshot, maximumTokens: maximum)
        }.value
        try Task.checkCancellation()
        var context = ChatContext(recordingTitle: recording.title, transcript: Transcript(), generationSettings: settings, retrievalUsed: retrieved.usedRetrieval)
        context.sourceChunks = retrieved.chunks
        let candidates = imageCandidates(recording: recording, chunks: retrieved.chunks, query: query, explicitSelection: selectedSourceIDs != nil)
        context.images = try await MultimodalContextService(storage: storage).prepare(candidates: candidates, capabilities: capabilities, allowed: allowImages)
        for image in context.images where !(context.sourceChunks?.contains { $0.id == image.chunkID } ?? false) {
            if let anchor = snapshot.chunks.first(where: { $0.id == image.chunkID }) { context.sourceChunks?.append(anchor) }
        }
        return context
    }

    func prepareSummary(recording: Recording, selectedSourceIDs: Set<UUID>?, provider: any LLMProvider,
                        allowImages: Bool) async throws -> SourceSummaryContext {
        let snapshot = try await RecordingContextSnapshot.load(recording: recording, selectedSourceIDs: selectedSourceIDs)
        let candidates = imageCandidates(recording: recording, chunks: snapshot.chunks, query: "", explicitSelection: true)
        let images = try await MultimodalContextService(storage: storage).prepare(candidates: candidates, capabilities: provider.inputCapabilities, allowed: allowImages)
        return SourceSummaryContext(chunks: snapshot.chunks, images: images)
    }

    private func imageCandidates(recording: Recording, chunks: [SourceChunk], query: String,
                                 explicitSelection: Bool) -> [MultimodalContextService.Candidate] {
        var seen = Set<UUID>()
        let imageChunks = chunks.filter { $0.sourceType == .image && seen.insert($0.sourceID).inserted }
        let queryLower = query.lowercased()
        let visualQuery = ["image", "diagram", "whiteboard", "chart", "picture", "obrázek", "diagram", "schéma", "tabule"].contains { queryLower.contains($0) }
        return imageChunks.filter { chunk in
            let filename = chunk.sourceName.lowercased()
            return explicitSelection || (!query.isEmpty && queryLower.contains(filename)) || (visualQuery && imageChunks.count == 1)
        }.compactMap { chunk in
            guard let source = recording.sources.first(where: { $0.id == chunk.sourceID }), source.isContextReady else { return nil }
            return .init(sourceID: source.id, chunkID: StableSourceID.make("image-\(source.id)"), url: storage.sourceURL(source))
        }
    }
}

struct SourceConversationHistory {
    @MainActor static func messages(session: ChatSession, recording: Recording, selectedSourceIDs: Set<UUID>?) -> [LLMChatMessage] {
        let selected = RecordingContextAvailability.readySourceIDs(recording, selectedSourceIDs: selectedSourceIDs)
        return session.orderedMessages.compactMap { message in
            if message.role == .system { return nil }
            if message.role == .assistant {
                guard let generation = recording.generationRecords.first(where: { $0.id == message.generationID }),
                      let data = generation.selectedSourceIDsData,
                      let ids = try? JSONDecoder().decode([UUID].self, from: data), Set(ids).isSubset(of: selected) else { return nil }
            }
            return LLMChatMessage(role: message.role, content: message.text)
        }
    }
}
