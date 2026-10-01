import Foundation
import SwiftData

@Model
final class Transcript {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var languageCode: String?
    var sourceName: String?
    var isMock: Bool = false
    var generationID: UUID?
    var historicalRecording: Recording?
    var recording: Recording?
    var source: RecordingSource?
    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.transcript)
    var segments: [TranscriptSegment] = []

    var orderedSegments: [TranscriptSegment] {
        segments.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    init(id: UUID = UUID(), languageCode: String? = nil, createdAt: Date = .now,
         sourceName: String? = nil, isMock: Bool = false) {
        self.id = id
        self.languageCode = languageCode
        self.createdAt = createdAt
        self.sourceName = sourceName
        self.isMock = isMock
    }
}
