import Foundation

/// Transient state for one attempt. Relaunching returns to idle or completed;
/// cancelled and failed attempts never leave a partial transcript in the library.
enum TranscriptionState: Equatable, Sendable {
    case idle
    case preparing
    case transcribing
    case saving
    case completed
    case failed(message: String)
    case cancelled

    var isProcessing: Bool {
        switch self {
        case .preparing, .transcribing, .saving: true
        default: false
        }
    }

    var canCancel: Bool { self == .preparing || self == .transcribing }

    var title: String {
        switch self {
        case .idle: "Ready to transcribe"
        case .preparing: "Preparing audio…"
        case .transcribing: "Transcribing…"
        case .saving: "Saving transcript…"
        case .completed: "Transcription completed"
        case .failed: "Transcription failed"
        case .cancelled: "Transcription cancelled"
        }
    }
}
