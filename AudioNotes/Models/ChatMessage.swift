import Foundation
import SwiftData

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

enum ChatMessageStatus: String, Codable, Sendable {
    case completed
    case interrupted
    case failed
}

public struct TranscriptReference: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var segmentID: UUID?
    public var startTime: TimeInterval
    public var endTime: TimeInterval?
    public var speaker: String?
    public var label: String?
    public var excerpt: String?

    public init(
        id: UUID = UUID(),
        segmentID: UUID? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval? = nil,
        speaker: String? = nil,
        label: String? = nil,
        excerpt: String? = nil
    ) {
        self.id = id
        self.segmentID = segmentID
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.label = label
        self.excerpt = excerpt
    }
}

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var role: ChatRole
    var text: String
    var createdAt: Date
    var statusRaw: String = ChatMessageStatus.completed.rawValue
    var references: [TranscriptReference] = []
    var session: ChatSession?
    var sourceReferencesData: Data?
    var sourceReferences: [SourceReference] {
        get { sourceReferencesData.flatMap { try? JSONDecoder().decode([SourceReference].self, from: $0) } ?? [] }
        set { sourceReferencesData = try? JSONEncoder().encode(newValue) }
    }
    var projectCitationsData: Data?
    var projectCitations: [ProjectCitation] {
        get { projectCitationsData.flatMap { try? JSONDecoder().decode([ProjectCitation].self, from: $0) } ?? [] }
        set { projectCitationsData = try? JSONEncoder().encode(newValue) }
    }
    var generationID: UUID?

    var content: String {
        get { text }
        set { text = newValue }
    }

    var status: ChatMessageStatus {
        get { ChatMessageStatus(rawValue: statusRaw) ?? .completed }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        createdAt: Date = .now,
        status: ChatMessageStatus = .completed,
        references: [TranscriptReference] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.statusRaw = status.rawValue
        self.references = references
    }
}
