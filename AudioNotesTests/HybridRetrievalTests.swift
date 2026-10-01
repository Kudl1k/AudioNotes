import Foundation
import Testing
@testable import AudioNotes

private struct FixtureEmbeddingProvider: EmbeddingProvider {
    let modelVersion = "fixture-v1"
    let identifier = "fixture-local"
    let dimensions = 2
    let maxInputTokens = 128
    let isLocal = true
    let values: [[Float]]
    func embed(_ texts: [String]) async throws -> [[Float]] { values }
}

@Suite struct HybridRetrievalTests {
    private func match(_ key: String, score: Double) -> RetrievalMatch {
        let id = StableSourceID.make(key)
        let chunk = SourceChunk(id: id, sourceID: id, sourceName: key, sourceType: .document,
                                text: key, locator: .document(section: key, start: 0, end: key.count), origin: .nativeText)
        let document = RetrievalDocument(id: id, projectID: nil, recordingID: nil, recordingTitle: nil,
            contentType: .plainText, chunk: chunk, unitIDs: [id], contentRevision: id)
        return RetrievalMatch(document: document, score: score, bodyScore: score, metadataBoost: 0, phraseBoost: 0)
    }

    @Test func reciprocalRankFusionHandlesOverlapAndBackendOnlyResultsDeterministically() {
        let a = match("lexical-and-semantic", score: 10)
        let b = match("lexical-only", score: 8)
        let c = match("semantic-only", score: 0.9)
        let first = RetrievalRankFusion.fuse(lexical: [a, b], semantic: [a, c], limit: 3)
        let second = RetrievalRankFusion.fuse(lexical: [a, b], semantic: [a, c], limit: 3)
        #expect(first.map { $0.document.id } == [a.document.id, b.document.id, c.document.id])
        #expect(first.map { $0.document.id } == second.map { $0.document.id })
    }

    @Test func semanticIndexNormalizesAndRejectsWrongDimensionsOrRemoteProvider() throws {
        let one = match("one", score: 0), two = match("two", score: 0)
        let provider = FixtureEmbeddingProvider(values: [[3, 4], [1, 0]])
        let index = try SemanticIndex(provider: provider, documents: [one.document, two.document], vectors: provider.values)
        let ranked = try index.search(queryVector: [1, 0], options: .init(limit: 2))
        #expect(ranked.map { $0.document.id } == [two.document.id, one.document.id])
        #expect(throws: SemanticRetrievalError.dimensionMismatch) {
            try index.search(queryVector: [1, 0, 0], options: .init())
        }
        // The provider's explicit locality contract is enforced by the index.
        #expect(throws: SemanticRetrievalError.invalidIndex) {
            try SemanticIndex(provider: NonLocalFixtureProvider(), documents: [one.document], vectors: [[1, 0]])
        }
    }
}

private struct NonLocalFixtureProvider: EmbeddingProvider {
    let modelVersion = "remote-v1"
    let identifier = "remote"
    let dimensions = 2
    let maxInputTokens = 128
    let isLocal = false
    func embed(_ texts: [String]) async throws -> [[Float]] { [[1, 0]] }
}
