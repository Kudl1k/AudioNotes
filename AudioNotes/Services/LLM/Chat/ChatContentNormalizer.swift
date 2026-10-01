import Foundation

/// Compatibility guard at the response boundary, never a source of references.
/// Only structured IDs resolved against this recording can become Sources.
struct ChatContentNormalizer {
    private static let uuidPattern = "[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"
    private static let artifactRegex = try! NSRegularExpression(pattern: [
        "【(?:\(uuidPattern)|[0-9]+\\??|malformed-reference|[^】\\n]*segment[^】\\n]*)】",
        "\\[segment_id\\s*=\\s*[^\\]\\n]*\\]",
        "(?<![0-9:])[0-9]{1,2}:[0-9]{2}[0-9]{1,2}:[0-9]{2}(?![0-9:])"
    ].joined(separator: "|"))
    private static let uuidRegex = try! NSRegularExpression(pattern: uuidPattern)

    static func clean(_ markdown: String, references: [TranscriptReference] = [], streaming: Bool = false, internalSegmentIDs: @autoclosure () -> [UUID] = []) -> String {
        var result = artifactRegex.stringByReplacingMatches(
            in: markdown, range: NSRange(markdown.startIndex..., in: markdown), withTemplate: ""
        )
        // Scan the response once, rather than scanning it for every transcript segment.
        // Only authoritative IDs are removed; ordinary UUIDs remain intact.
        let matches = uuidRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        if !matches.isEmpty {
            let internalIDs = Set(internalSegmentIDs() + references.compactMap(\.segmentID))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result),
                      let id = UUID(uuidString: String(result[range])), internalIDs.contains(id) else { continue }
                result.removeSubrange(range)
            }
        }
        // Hide an unfinished machine marker while deltas arrive, without delaying prose.
        if streaming, let opening = result.range(of: "【", options: .backwards),
           !result[opening.upperBound...].contains("】") {
            result.removeSubrange(opening.lowerBound...)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validated(_ response: LLMChatResponse, against segments: [TranscriptSegmentSnapshot]) -> LLMChatResponse {
        let references = TranscriptReferenceResolver().resolve(
            segmentIDs: response.references.compactMap { $0.segmentID?.uuidString }, against: segments
        )
        return LLMChatResponse(content: clean(response.content, references: references, internalSegmentIDs: segments.map(\.id)), references: references, usage: response.usage, modelID: response.modelID)
    }
}

/// Display grouping retains the original references in the message.
struct ChatSourceGroup: Identifiable {
    var references: [TranscriptReference]
    var id: UUID { references[0].segmentID ?? references[0].id }
    var startTime: TimeInterval { references[0].startTime }
}

struct ChatSourcePresentation {
    static func groups(_ references: [TranscriptReference]) -> [ChatSourceGroup] {
        var seen = Set<UUID>()
        let sorted = references.filter {
            guard let id = $0.segmentID, $0.startTime.isFinite, $0.startTime >= 0 else { return false }
            return seen.insert(id).inserted
        }.sorted { $0.startTime < $1.startTime }
        var groups: [ChatSourceGroup] = []
        for reference in sorted {
            if let last = groups.last, let end = last.references.last?.endTime,
               reference.startTime >= last.startTime, reference.startTime <= end + 1 {
                groups[groups.count - 1].references.append(reference)
            } else {
                groups.append(ChatSourceGroup(references: [reference]))
            }
        }
        return groups
    }
}
