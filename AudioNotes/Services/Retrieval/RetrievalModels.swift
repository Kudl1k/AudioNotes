import Foundation

enum RetrievalScope: Hashable, Codable, Sendable {
    case recording(UUID)
    case project(UUID)
}

enum RetrievalContentType: String, Codable, CaseIterable, Sendable {
    case transcript, pdfText, imageOCR, markdown, plainText
}

struct RetrievalDocument: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let projectID: UUID?
    let recordingID: UUID?
    let recordingTitle: String?
    let contentType: RetrievalContentType
    let chunk: SourceChunk
    /// Original persisted units/segments, never positions or model-generated locations.
    let unitIDs: [UUID]
    let contentRevision: UUID
    var sourceID: UUID { chunk.sourceID }
    var text: String { chunk.text }
    var title: String { recordingTitle ?? chunk.sourceName }
}

struct RetrievalOptions: Sendable {
    enum Ownership: Sendable { case all, recordings, projectSources }
    var ownership: Ownership = .all
    var recordingIDs: Set<UUID>?
    var sourceIDs: Set<UUID>?
    var contentTypes: Set<RetrievalContentType>?
    var limit: Int = 20
    var maximumTokens: Int = 12_000
    var diversify: Bool = true
    var includeTranscriptNeighbors: Bool = false

    func includes(_ document: RetrievalDocument) -> Bool {
        if ownership == .recordings && document.recordingID == nil { return false }
        if ownership == .projectSources && document.recordingID != nil { return false }
        if let recordingIDs, document.recordingID.map(recordingIDs.contains) != true { return false }
        if let sourceIDs, !sourceIDs.contains(document.sourceID) { return false }
        if let contentTypes, !contentTypes.contains(document.contentType) { return false }
        return true
    }
}

struct RetrievalRecordingMetadata: Codable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID?
    let title: String
    let hasTranscript: Bool
}

struct RetrievalCoverage: Codable, Equatable, Sendable {
    var searchableRecordings = 0
    var untranscribedRecordings = 0
    var searchableSources = 0
    var processingSources = 0
    var failedSources = 0
}

struct RetrievalMatch: Sendable {
    let document: RetrievalDocument
    let score: Double
    let bodyScore: Double
    let metadataBoost: Double
    let phraseBoost: Double
}

struct RetrievalStatistics: Sendable {
    let documentCount: Int
    let rebuiltIndex: Bool
    let indexBuildDuration: Duration
    let queryDuration: Duration
}

struct RetrievalResult: Sendable {
    let query: String
    let scope: RetrievalScope
    let matches: [RetrievalMatch]
    let coverage: RetrievalCoverage
    let recordings: [RetrievalRecordingMetadata]
    let statistics: RetrievalStatistics
    let context: ContextPackage
}

struct ContextEntry: Codable, Sendable {
    let document: RetrievalDocument
    let relevance: Double
    var reference: SourceReference {
        let chunk = document.chunk
        return .init(sourceID: chunk.sourceID, chunkID: chunk.id, sourceName: chunk.sourceName,
                     sourceType: chunk.sourceType, locator: chunk.locator, excerpt: String(chunk.text.prefix(160)))
    }
}

struct ContextPackage: Codable, Sendable {
    static let groundingInstructions = RetrievedSourceContextBuilder.grounding
    let query: String
    let scope: RetrievalScope
    let entries: [ContextEntry]
    let estimatedTokenCount: Int

    /// Pass only as user-role DATA, with grounding supplied separately in system instructions.
    func serializedSourceData() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(entries), as: UTF8.self)
    }
}

struct RetrievalBudget: Sendable {
    let contextWindow: Int
    var outputReserve: Int = 8000
    var systemTokens: Int = 4000
    var historyTokens: Int = 0
    var imageTokens: Int = 0
    var maximumRetrievalTokens: Int = 12_000
    var availableTokens: Int {
        max(0, min(maximumRetrievalTokens, contextWindow - outputReserve - systemTokens - historyTokens - imageTokens))
    }
}
