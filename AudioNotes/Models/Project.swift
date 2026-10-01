import Foundation
import SwiftData

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var projectDescription: String?
    var createdAt: Date
    var updatedAt: Date

    // Deletion preserves recordings unless the repository explicitly deletes them.
    @Relationship(deleteRule: .nullify, inverse: \Recording.project)
    var recordings: [Recording] = []
    @Relationship(deleteRule: .cascade, inverse: \RecordingSource.project)
    var sources: [RecordingSource] = []

    @Relationship(deleteRule: .cascade, inverse: \ChatSession.project)
    var chatSessions: [ChatSession] = []
    @Relationship(deleteRule: .cascade, inverse: \GenerationRecord.project)
    var generationRecords: [GenerationRecord] = []

    init(id: UUID = UUID(), name: String, projectDescription: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.projectDescription = projectDescription
        self.createdAt = createdAt
        updatedAt = createdAt
    }
}
