import Foundation

struct TranscriptSegmentSnapshot: Sendable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speaker: String?
    let text: String

    init(id: UUID, startTime: TimeInterval, endTime: TimeInterval, speaker: String?, text: String) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.text = text
    }

    init(segment: TranscriptSegment) {
        self.id = segment.id
        self.startTime = segment.startTime
        self.endTime = segment.endTime
        self.speaker = segment.speaker
        self.text = segment.text
    }
}

extension Transcript {
    var segmentSnapshots: [TranscriptSegmentSnapshot] {
        orderedSegments.map(TranscriptSegmentSnapshot.init)
    }
}

struct TranscriptReferenceResolver: Sendable {
    init() {}

    /// Validates an array of model-provided segment ID strings against authoritative segments.
    /// Fabricated, nonexistent, or malformed segment IDs are rejected.
    /// Timestamps, speakers, and labels are strictly derived from the verified segments.
    func resolve(
        segmentIDs: [String],
        against segments: [TranscriptSegmentSnapshot]
    ) -> [TranscriptReference] {
        guard !segmentIDs.isEmpty, !segments.isEmpty else {
            return []
        }

        var segmentMap: [UUID: TranscriptSegmentSnapshot] = [:]
        for segment in segments {
            segmentMap[segment.id] = segment
        }

        var results: [TranscriptReference] = []
        var seenIDs: Set<UUID> = []

        for rawID in segmentIDs {
            let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let uuid = UUID(uuidString: trimmed) else {
                continue
            }

            guard let matchedSegment = segmentMap[uuid] else {
                // Reject nonexistent or cross-recording segment IDs
                continue
            }

            guard !seenIDs.contains(uuid) else {
                continue
            }
            seenIDs.insert(uuid)

            let timeLabel = AudioTime.format(matchedSegment.startTime)
            let displayLabel: String
            if let speaker = matchedSegment.speaker, !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayLabel = "\(timeLabel) — \(speaker)"
            } else {
                displayLabel = timeLabel
            }

            let trimmedText = matchedSegment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt: String
            if trimmedText.count > 120 {
                excerpt = String(trimmedText.prefix(120)) + "..."
            } else {
                excerpt = trimmedText
            }

            let reference = TranscriptReference(
                id: UUID(),
                segmentID: matchedSegment.id,
                startTime: matchedSegment.startTime,
                endTime: matchedSegment.endTime,
                speaker: matchedSegment.speaker,
                label: displayLabel,
                excerpt: excerpt
            )
            results.append(reference)
        }

        return results.sorted { $0.startTime < $1.startTime }
    }

    func resolve(
        segmentIDs: [String],
        against transcript: Transcript
    ) -> [TranscriptReference] {
        resolve(segmentIDs: segmentIDs, against: transcript.segmentSnapshots)
    }
}
