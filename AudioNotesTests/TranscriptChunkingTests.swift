import Foundation
import Testing
@testable import AudioNotes

struct TranscriptChunkingTests {
    private func fixtures(_ texts: [String]) -> [TranscriptSegmentSnapshot] {
        texts.enumerated().map { index, text in
            TranscriptSegmentSnapshot(id: UUID(), startTime: Double(index * 10), endTime: Double(index * 10 + 8), speaker: index.isMultiple(of: 2) ? "Alex" : "Sam", text: text)
        }
    }

    @Test func chunkingPreservesEverySegmentAndOverlap() {
        let segments = fixtures((0..<32).map { "Segment \($0) " + String(repeating: "detail ", count: 22) })
        let chunks = TranscriptChunker(targetCharacters: 1_000, overlapSegments: 2).chunks(from: segments)
        #expect(chunks.count > 1)
        #expect(chunks.map(\.sequenceIndex) == Array(chunks.indices))
        #expect(Set(chunks.flatMap(\.segmentIDs)) == Set(segments.map(\.id)))
        #expect(chunks[0].segmentIDs.suffix(2).elementsEqual(chunks[1].segmentIDs.prefix(2)))
        #expect(chunks.first?.startTime == segments.first?.startTime)
        #expect(chunks.last?.endTime == segments.last?.endTime)
    }

    @Test func lexicalRetrievalFindsContentNearTranscriptEnd() {
        let segments = fixtures((0..<36).map { index in
            index == 33 ? "Morgan approved the revised accessibility budget for captions and screen reader testing." : "Routine agenda note item \(index) with no related finance information."
        })
        let chunks = TranscriptChunker(targetCharacters: 1_000, overlapSegments: 1).chunks(from: segments)
        let retrieved = LexicalTranscriptRetrievalStrategy().retrieve(query: "What did Morgan approve about accessibility?", chunks: chunks, maximumTokens: 2_000)
        #expect(retrieved.contains { $0.segments.contains { $0.text.contains("accessibility budget") } })
    }

    @Test func retrievalQueryUsesRecentConversationForFollowUps() {
        let history = [
            LLMChatMessage(role: .user, content: "What did Peter propose?"),
            LLMChatMessage(role: .assistant, content: "He proposed moving the release to November."),
            LLMChatMessage(role: .user, content: "Why?")
        ]
        let query = TranscriptRetrievalQueryBuilder().build(from: history)
        #expect(query.contains("moving the release to November"))
        #expect(query.contains("Why?"))
    }

    @Test func chunksKeepUnicodeAndSpeakerProvenance() {
        let segments = fixtures(["你好，世界 🌍", "Доброе утро", "مرحبا بالعالم", "Café déjà vu"])
        let chunks = TranscriptChunker(targetCharacters: 1_000, overlapSegments: 0).chunks(from: segments)
        #expect(chunks.flatMap(\.segments).map(\.id) == segments.map(\.id))
        #expect(chunks.flatMap(\.speakerNames).contains("Alex"))
        #expect(chunks.map(\.text).joined().contains("你好，世界 🌍"))
    }
}
