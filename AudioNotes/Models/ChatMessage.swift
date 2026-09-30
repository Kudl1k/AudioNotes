import Foundation
import SwiftData

enum ChatRole: String, Codable, Sendable {
    case user, assistant, system
}

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var role: ChatRole
    var text: String
    var createdAt: Date
    var session: ChatSession?

    init(id: UUID = UUID(), role: ChatRole, text: String, createdAt: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}
