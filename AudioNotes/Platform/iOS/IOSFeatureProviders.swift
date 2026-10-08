#if os(iOS)
import Foundation

/// Keeps review navigation on the same library-owned models, with strictly offline providers.
@MainActor
enum IOSFeatureProviders {
    static func transcription(_ services: AppServices) -> any TranscriptionProviderResolving {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--performance-fixtures") {
            if ProcessInfo.processInfo.arguments.contains("--ios-local-ai-review") { return FixedTranscriptionProviderResolver(provider: IOSLocalTranscriptionFixture()) }
            return FixedTranscriptionProviderResolver(provider: MockTranscriptionProvider())
        }
#endif
        return services.transcriptionResolver
    }
    static func llm(_ services: AppServices) -> any LLMProviderResolving {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--performance-fixtures") {
            if ProcessInfo.processInfo.arguments.contains("--ios-local-ai-review") { return FixedLLMProviderResolver(provider: LocalLLMProvider(runtime: IOSLocalLanguageFixture())) }
            return FixedLLMProviderResolver(provider: MockLLMProvider())
        }
#endif
        return services.llmResolver
    }
}
#endif
