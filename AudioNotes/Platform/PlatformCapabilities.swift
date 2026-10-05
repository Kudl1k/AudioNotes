import Foundation

/// Explicit representation of host platform capabilities.
/// Avoids scattering compile-time `#if os(...)` checks throughout feature views and view models.
struct PlatformCapabilities: Sendable, Equatable {
    var supportsClaudeCLI: Bool
    var supportsSparkleUpdates: Bool
    var supportsFinderReveal: Bool

    static let current: PlatformCapabilities = {
#if os(macOS)
        PlatformCapabilities(
            supportsClaudeCLI: true,
            supportsSparkleUpdates: true,
            supportsFinderReveal: true
        )
#else
        PlatformCapabilities(
            supportsClaudeCLI: false,
            supportsSparkleUpdates: false,
            supportsFinderReveal: false
        )
#endif
    }()

    func isSupported(llmProvider: LLMProviderID) -> Bool {
        switch llmProvider {
        case .onDevice:
#if os(iOS)
            if #available(iOS 26, *) { return true }
#endif
            return false
        case .anthropic:
            return supportsClaudeCLI
        case .gemini:
            return true
        case .mock:
#if DEBUG
            return true
#else
            return false
#endif
        case .openAI:
            return true
        case .ollama, .llamaCpp:
#if os(macOS)
            return true
#else
            return false
#endif
        }
    }

    func isSupported(transcriptionProvider: TranscriptionProviderID) -> Bool {
        switch transcriptionProvider {
        case .openAI, .gemini:
            return true
        case .mock:
#if DEBUG
            return true
#else
            return false
#endif
        case .localWhisper:
#if arch(arm64)
            return true
#else
            return false
#endif
        }
    }
}

extension LLMProviderID {
    var isSupportedOnCurrentPlatform: Bool {
        PlatformCapabilities.current.isSupported(llmProvider: self)
    }

    static var currentPlatformSelectable: [Self] {
        selectable.filter { $0.isSupportedOnCurrentPlatform }
    }
}

extension TranscriptionProviderID {
    var isSupportedOnCurrentPlatform: Bool {
        PlatformCapabilities.current.isSupported(transcriptionProvider: self)
    }

    static var currentPlatformSelectable: [Self] {
        selectable.filter { $0.isSupportedOnCurrentPlatform }
    }
}
