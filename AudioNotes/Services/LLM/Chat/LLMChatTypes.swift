import Foundation

struct LLMChatMessage: Codable, Sendable, Hashable {
    var role: ChatRole
    var content: String

    init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

struct ChatContext: @unchecked Sendable {
    var recordingTitle: String
    var transcript: Transcript
    var summary: Summary?
    var generationSettings: LLMGenerationSettings?
    var retrievedSegments: [TranscriptSegmentSnapshot]?
    var sourceChunks: [SourceChunk]? = nil
    var projectEvidence: String? = nil
    var images: [LLMImageInput] = []
    var retrievalUsed: Bool

    init(
        recordingTitle: String,
        transcript: Transcript,
        summary: Summary? = nil,
        generationSettings: LLMGenerationSettings? = nil,
        retrievedSegments: [TranscriptSegmentSnapshot]? = nil,
        retrievalUsed: Bool = false
    ) {
        self.recordingTitle = recordingTitle
        self.transcript = transcript
        self.summary = summary
        self.generationSettings = generationSettings
        self.retrievedSegments = retrievedSegments
        self.retrievalUsed = retrievalUsed
    }
}

struct LLMChatResponse: Sendable, Equatable {
    var content: String
    var references: [TranscriptReference]
    var sourceReferences: [SourceReference] = []
    var usage: GenerationUsage?
    var modelID: String?

    init(content: String, references: [TranscriptReference] = [], usage: GenerationUsage? = nil, modelID: String? = nil, sourceReferences: [SourceReference] = []) {
        self.sourceReferences = sourceReferences
        self.content = ChatContentNormalizer.clean(content, references: references, internalSegmentIDs: sourceReferences.map(\.chunkID))
        self.references = references
        self.usage = usage
        self.modelID = modelID
    }
}

enum ChatStreamEvent: Sendable {
    case textDelta(String)
    case references([TranscriptReference])
    case usage(GenerationUsage)
    case completed(LLMChatResponse)
}
