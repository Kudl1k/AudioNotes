import Foundation

public enum ChatGenerationState: Equatable, Sendable {
    case idle
    case preparing
    case waitingForFirstToken
    case streaming
    case completed
    case failed(String)
    case cancelled

    public var isGenerating: Bool {
        switch self {
        case .preparing, .waitingForFirstToken, .streaming:
            return true
        case .idle, .completed, .failed, .cancelled:
            return false
        }
    }
}
