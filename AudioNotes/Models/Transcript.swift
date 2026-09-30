import Foundation
import SwiftData

@Model
final class Transcript {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var languageCode: String?
    var recording: Recording?
    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.transcript)
    var segments: [TranscriptSegment] = []

    var orderedSegments: [TranscriptSegment] {
        segments.sorted { $0.position < $1.position }
    }

    init(id: UUID = UUID(), languageCode: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.languageCode = languageCode
        self.createdAt = createdAt
    }
}
