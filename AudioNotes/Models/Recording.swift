import Foundation
import SwiftData

@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var title: String
    var importedAt: Date
    /// A relative filename keeps the library portable across sandbox locations.
    var audioFileName: String
    var originalFileName: String
    var duration: TimeInterval

    @Relationship(deleteRule: .cascade, inverse: \Transcript.recording)
    var transcript: Transcript?
    @Relationship(deleteRule: .cascade, inverse: \Summary.recording)
    var summary: Summary?
    @Relationship(deleteRule: .cascade, inverse: \ChatSession.recording)
    var chatSessions: [ChatSession] = []

    init(id: UUID = UUID(), title: String, audioFileName: String,
         originalFileName: String, duration: TimeInterval, importedAt: Date = .now) {
        self.id = id
        self.title = title
        self.audioFileName = audioFileName
        self.originalFileName = originalFileName
        self.duration = duration
        self.importedAt = importedAt
    }
}
