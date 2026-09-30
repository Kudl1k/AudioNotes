import Foundation
import SwiftData

@Model
final class TranscriptSegment {
    @Attribute(.unique) var id: UUID
    var position: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speaker: String?
    var transcript: Transcript?

    init(id: UUID = UUID(), position: Int, startTime: TimeInterval,
         endTime: TimeInterval, text: String, speaker: String? = nil) {
        self.id = id
        self.position = position
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
    }
}
