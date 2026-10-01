import Foundation

struct TranscriptChunk: Identifiable, Sendable {
    let id: UUID
    let sequenceIndex: Int
    let segments: [TranscriptSegmentSnapshot]
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speakerNames: [String]
    let text: String

    var segmentIDs: [UUID] { segments.map(\.id) }
    var approximateTokens: Int { TranscriptTokenEstimator.estimate(text) }

    init(sequenceIndex: Int, segments: [TranscriptSegmentSnapshot]) {
        self.id = UUID()
        self.sequenceIndex = sequenceIndex
        self.segments = segments
        self.startTime = segments.first?.startTime ?? 0
        self.endTime = segments.last?.endTime ?? startTime
        self.speakerNames = Array(Set(segments.compactMap { $0.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        self.text = segments.map { segment in
            let speaker = segment.speaker.map { "\($0): " } ?? ""
            return "[\(AudioTime.format(segment.startTime))–\(AudioTime.format(segment.endTime))] \(speaker)\(segment.text)"
        }.joined(separator: "\n")
    }
}

enum TranscriptTokenEstimator {
    /// Approximate context sizing only. This is not provider usage or billing data.
    static func estimate(_ text: String) -> Int { max(1, (text.utf8.count + 3) / 4) }
}

struct TranscriptChunker: Sendable {
    var targetCharacters: Int
    var overlapSegments: Int

    init(targetCharacters: Int = 24_000, overlapSegments: Int = 2) {
        self.targetCharacters = max(1_000, targetCharacters)
        self.overlapSegments = max(0, overlapSegments)
    }

    func chunks(from segments: [TranscriptSegmentSnapshot]) -> [TranscriptChunk] {
        let ordered = segments.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard !ordered.isEmpty else { return [] }

        var groups: [[TranscriptSegmentSnapshot]] = []
        var current: [TranscriptSegmentSnapshot] = []
        var currentCharacters = 0
        for segment in ordered {
            let size = segment.text.count + (segment.speaker?.count ?? 0) + 48
            if !current.isEmpty, currentCharacters + size > targetCharacters {
                groups.append(current)
                let overlap = Array(current.suffix(min(overlapSegments, current.count)))
                current = overlap
                currentCharacters = overlap.reduce(0) { $0 + $1.text.count + ($1.speaker?.count ?? 0) + 48 }
            }
            current.append(segment)
            currentCharacters += size
        }
        if !current.isEmpty { groups.append(current) }
        return groups.enumerated().map { TranscriptChunk(sequenceIndex: $0.offset, segments: $0.element) }
    }
}

struct TranscriptRetrievalQueryBuilder: Sendable {
    func build(from history: [LLMChatMessage]) -> String {
        let recent = history.suffix(6)
        return recent.map { "\($0.role == .assistant ? "Previous answer" : "Question/follow-up"): \($0.content)" }.joined(separator: "\n")
    }
}

struct RetrievedTranscriptChunks: Sendable {
    let chunks: [TranscriptChunk]
    let usedRetrieval: Bool
    var segments: [TranscriptSegmentSnapshot] {
        var seen = Set<UUID>()
        return chunks.flatMap(\.segments).filter { seen.insert($0.id).inserted }.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

protocol TranscriptRetrievalStrategy: Sendable {
    func retrieve(query: String, chunks: [TranscriptChunk], maximumTokens: Int) -> [TranscriptChunk]
}

protocol EmbeddingProvider: Sendable {
    var modelVersion: String { get }
    /// Stable provider/model identity. Vectors from different identities are never mixed.
    var identifier: String { get }
    var dimensions: Int { get }
    var maxInputTokens: Int { get }
    /// Semantic retrieval accepts local providers only. Remote embeddings are deliberately unsupported.
    var isLocal: Bool { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension EmbeddingProvider {
    var identifier: String { modelVersion }
    var dimensions: Int { 0 }
    var maxInputTokens: Int { 8_192 }
    var isLocal: Bool { false }
}

struct LexicalTranscriptRetrievalStrategy: TranscriptRetrievalStrategy {
    func retrieve(query: String, chunks: [TranscriptChunk], maximumTokens: Int) -> [TranscriptChunk] {
        let queryTerms = Self.terms(query)
        guard !queryTerms.isEmpty else { return Array(chunks.prefix(1)) }
        let phrase = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ranked = chunks.map { chunk -> (TranscriptChunk, Double) in
            let terms = Self.terms(chunk.text)
            let frequencies = Dictionary(terms.map { ($0, 1) }, uniquingKeysWith: +)
            let score = queryTerms.reduce(0.0) { total, term in
                total + (Double(frequencies[term, default: 0]) / sqrt(Double(max(1, terms.count))))
            } + (chunk.text.lowercased().contains(phrase) && phrase.count > 3 ? 2.0 : 0.0)
            return (chunk, score)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.sequenceIndex < $1.0.sequenceIndex
        }

        var chosen: [TranscriptChunk] = []
        var usedTokens = 0
        for (chunk, score) in ranked where score > 0 {
            if !chosen.isEmpty && usedTokens + chunk.approximateTokens > maximumTokens { continue }
            chosen.append(chunk)
            usedTokens += chunk.approximateTokens
            if usedTokens >= maximumTokens { break }
        }
        if chosen.isEmpty, let first = chunks.first { chosen = [first] }
        return chosen.sorted { $0.sequenceIndex < $1.sequenceIndex }
    }

    private static func terms(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
    }
}

struct TranscriptRetriever: Sendable {
    var chunker: TranscriptChunker
    var strategy: any TranscriptRetrievalStrategy
    var retrievalThresholdTokens: Int

    init(chunker: TranscriptChunker = TranscriptChunker(), strategy: any TranscriptRetrievalStrategy = LexicalTranscriptRetrievalStrategy(), retrievalThresholdTokens: Int = 18_000) {
        self.chunker = chunker
        self.strategy = strategy
        self.retrievalThresholdTokens = retrievalThresholdTokens
    }

    func retrieve(query: String, transcript: Transcript, maximumTokens: Int = 12_000) -> RetrievedTranscriptChunks {
        retrieve(query: query, segments: transcript.segmentSnapshots, maximumTokens: maximumTokens)
    }

    func retrieve(query: String, segments: [TranscriptSegmentSnapshot], maximumTokens: Int = 12_000) -> RetrievedTranscriptChunks {
        let chunks = chunker.chunks(from: segments)
        let totalTokens = chunks.reduce(0) { $0 + $1.approximateTokens }
        guard totalTokens > retrievalThresholdTokens else {
            return RetrievedTranscriptChunks(chunks: chunks, usedRetrieval: false)
        }
        return RetrievedTranscriptChunks(chunks: strategy.retrieve(query: query, chunks: chunks, maximumTokens: maximumTokens), usedRetrieval: true)
    }
}
