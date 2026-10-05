import Foundation

/// Library-owned admission gate. Heavy native engines never overlap in this process.
actor LocalInferenceCoordinator {
    private var active = false
    func acquire() throws {
        try Task.checkCancellation()
        guard !active else { throw LocalAIError.modelBusy }
        active = true
    }
    func release() { active = false }
}
