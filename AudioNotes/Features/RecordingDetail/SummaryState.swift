import Foundation

enum SummaryState: Equatable, Sendable {
    case idle
    case generating
    case completed
    case failed(message: String)
    case cancelled

    var isGenerating: Bool {
        if case .generating = self { return true }
        return false
    }

    var canCancel: Bool {
        isGenerating
    }
}
