import Foundation

/// Stable scene/sidebar identity independent of names and background processing.
enum LibraryDestination: Hashable, Sendable {
    case allRecordings
    case recording(UUID)
    case project(UUID)

    var persistedValue: String {
        switch self {
        case .allRecordings: ""
        case .recording(let id): id.uuidString // Preserve M11 scene values.
        case .project(let id): "project:" + id.uuidString
        }
    }

    init(persistedValue: String) {
        if persistedValue.hasPrefix("project:"), let id = UUID(uuidString: String(persistedValue.dropFirst(8))) {
            self = .project(id)
        } else if let id = UUID(uuidString: persistedValue) {
            self = .recording(id)
        } else { self = .allRecordings }
    }

    func available(recordingIDs: Set<UUID>, projectIDs: Set<UUID>) -> Self {
        switch self {
        case .recording(let id): recordingIDs.contains(id) ? self : .allRecordings
        case .project(let id): projectIDs.contains(id) ? self : .allRecordings
        case .allRecordings: self
        }
    }
}
