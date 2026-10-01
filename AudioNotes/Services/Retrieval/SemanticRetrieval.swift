import Foundation

/// Dense, in-memory cosine index over M12.2 retrieval documents. It is derived state;
/// authoritative text and provenance remain in RetrievalSnapshot.
struct SemanticIndex: Sendable {
    let providerID: String
    let modelVersion: String
    let dimensions: Int
    let documents: [RetrievalDocument]
    private let vectors: [[Float]]

    init(provider: any EmbeddingProvider, documents: [RetrievalDocument], vectors: [[Float]]) throws {
        guard provider.isLocal, !provider.identifier.isEmpty,
              vectors.count == documents.count, !vectors.isEmpty else { throw SemanticRetrievalError.invalidIndex }
        let dimension = provider.dimensions > 0 ? provider.dimensions : vectors.first?.count ?? 0
        guard dimension > 0, vectors.allSatisfy({ $0.count == dimension && $0.allSatisfy(\.isFinite) }) else {
            throw SemanticRetrievalError.dimensionMismatch
        }
        self.providerID = provider.identifier
        self.modelVersion = provider.modelVersion
        self.dimensions = dimension
        self.documents = documents
        self.vectors = vectors.map(Self.normalized)
    }

    func search(queryVector: [Float], options: RetrievalOptions) throws -> [RetrievalMatch] {
        try Task.checkCancellation()
        guard queryVector.count == dimensions, queryVector.allSatisfy(\.isFinite) else {
            throw SemanticRetrievalError.dimensionMismatch
        }
        let query = Self.normalized(queryVector)
        return documents.indices.filter { options.includes(documents[$0]) }.map { index in
            let score = zip(query, vectors[index]).reduce(0.0) { $0 + Double($1.0 * $1.1) }
            return RetrievalMatch(document: documents[index], score: score, bodyScore: score, metadataBoost: 0, phraseBoost: 0)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.document.id.uuidString < $1.document.id.uuidString
        }.prefix(max(0, options.limit)).map { $0 }
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1 * $1) })
        guard norm > 0, norm.isFinite else { return vector }
        return vector.map { Float(Double($0) / norm) }
    }
}

enum SemanticRetrievalError: Error, Sendable {
    case invalidIndex
    case dimensionMismatch
}

/// Reciprocal Rank Fusion keeps unrelated BM25 and cosine score scales separate.
enum RetrievalRankFusion {
    static let defaultConstant = 60

    static func fuse(lexical: [RetrievalMatch], semantic: [RetrievalMatch], limit: Int,
                     constant: Int = defaultConstant) -> [RetrievalMatch] {
        struct Ranked {
            let match: RetrievalMatch
            var score: Double
        }
        var merged: [UUID: Ranked] = [:]
        for (rank, match) in lexical.enumerated() {
            merged[match.document.id] = Ranked(match: match, score: 1 / Double(max(1, constant) + rank + 1))
        }
        for (rank, match) in semantic.enumerated() {
            let contribution = 1 / Double(max(1, constant) + rank + 1)
            if var existing = merged[match.document.id] {
                existing.score += contribution
                merged[match.document.id] = existing
            } else {
                merged[match.document.id] = Ranked(match: match, score: contribution)
            }
        }
        return merged.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.match.document.id.uuidString < $1.match.document.id.uuidString
        }.prefix(max(0, limit)).map {
            RetrievalMatch(document: $0.match.document, score: $0.score, bodyScore: $0.match.bodyScore,
                           metadataBoost: $0.match.metadataBoost, phraseBoost: $0.match.phraseBoost)
        }
    }
}
