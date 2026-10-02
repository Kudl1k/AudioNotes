import Foundation
import Observation

struct TranscriptDisplaySegment: Identifiable, Sendable, Equatable {
    let id: UUID
    let position: Int
    let startTime: TimeInterval
    let text: String
    let speaker: String?
    init(_ segment: TranscriptSegment) {
        id = segment.id; position = segment.position; startTime = segment.startTime
        text = segment.text; speaker = segment.speaker
    }
    static func ordered(_ rows: [Self]) -> [Self] {
        rows.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    static func matching(_ query: String, in rows: [Self]) -> [Self] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return rows }
        return rows.filter { $0.text.localizedCaseInsensitiveContains(query) || ($0.speaker?.localizedCaseInsensitiveContains(query) ?? false) }
    }
}

@MainActor
@Observable
final class TranscriptViewModel {
    private(set) var visibleSegments: [TranscriptDisplaySegment] = []
    private(set) var isLoading = false
    /// The query that produced `visibleSegments`; lets the view tell "no matches" from "search pending".
    private(set) var searchedQuery = ""
    @ObservationIgnored private var segments: [TranscriptDisplaySegment] = []
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var revision = UUID()

    func load(_ transcript: Transcript?) async {
        let revision = UUID()
        self.revision = revision
        isLoading = true
        let input = transcript?.segments.map(TranscriptDisplaySegment.init) ?? []
        let ordered = await Task.detached(priority: .userInitiated) { TranscriptDisplaySegment.ordered(input) }.value
        guard !Task.isCancelled, self.revision == revision else { return }
        segments = ordered
        isLoading = false
        await search(query, debounce: false)
    }
    func search(_ query: String, debounce: Bool = true) async {
        self.query = query
        let revision = revision
        do {
            if debounce { try await Task.sleep(for: .milliseconds(150)) }
            try Task.checkCancellation()
            let rows = segments
            let results = await Task.detached(priority: .userInitiated) { TranscriptDisplaySegment.matching(query, in: rows) }.value
            guard !Task.isCancelled, self.revision == revision, self.query == query else { return }
            visibleSegments = results
            searchedQuery = query
        } catch { /* Cancelled/superseded searches leave the displayed rows intact. */ }
    }
}
