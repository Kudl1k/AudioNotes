import Foundation

/// Maps technical errors from library editing to messages suitable for alerts.
/// AudioNotes' own editing errors already describe the problem; SwiftData and file-system
/// errors are replaced by the caller's context, because their descriptions are technical.
enum UserFacingError {
    static func message(for error: Error, fallback: String) -> String {
        switch error {
        case let error as ProjectEditingError: error.localizedDescription
        case let error as WorkspaceDeletionError: error.localizedDescription
        default: fallback
        }
    }
}
