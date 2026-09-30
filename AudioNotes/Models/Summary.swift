import Foundation
import SwiftData

@Model
final class Summary {
    @Attribute(.unique) var id: UUID
    var text: String
    var createdAt: Date
    var recording: Recording?

    init(id: UUID = UUID(), text: String, createdAt: Date = .now) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}
