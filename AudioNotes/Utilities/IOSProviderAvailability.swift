import Foundation

/// Pure mobile presentation policy; runtime provider privacy/capability gates remain authoritative.
enum IOSProviderAvailability {
    static func transcription(openAIKey: Bool, geminiConnected: Bool, includeMock: Bool = false) -> [TranscriptionProviderID] {
        var providers: [TranscriptionProviderID] = []
#if DEBUG
        if includeMock { providers.append(.mock) }
#endif
        if openAIKey { providers.append(.openAI) }
        if geminiConnected { providers.append(.gemini) }
        return providers
    }
}

extension RecordingViewModel {
    var hasTranscriptionOverrides: Bool { selectedProvider != nil || selectedModel != nil || selectedLanguage != nil }
    func resetTranscriptionOverrides() { selectedProvider = nil; selectedModel = nil; selectedLanguage = nil }
}
