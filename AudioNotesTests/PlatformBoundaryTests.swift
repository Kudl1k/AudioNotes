import Foundation
import SwiftUI
import Testing
@testable import AudioNotes

struct PlatformBoundaryTests {
    @Test func platformCapabilitiesReflectCurrentSystem() {
        let capabilities = PlatformCapabilities.current
#if os(macOS)
        #expect(capabilities.supportsClaudeCLI == true)
        #expect(capabilities.supportsSparkleUpdates == true)
        #expect(capabilities.supportsFinderReveal == true)
        #expect(capabilities.isSupported(llmProvider: .anthropic) == true)
        #expect(capabilities.isSupported(llmProvider: .openAI) == true)
        #expect(capabilities.isSupported(llmProvider: .ollama) == true)
        #expect(capabilities.isSupported(llmProvider: .llamaCpp) == true)
        #expect(capabilities.isSupported(llmProvider: .gemini) == true)
        #expect(capabilities.isSupported(transcriptionProvider: .localWhisper) == true)
#elseif os(iOS)
        #expect(capabilities.supportsClaudeCLI == false)
        #expect(capabilities.supportsSparkleUpdates == false)
        #expect(capabilities.supportsFinderReveal == false)
        #expect(capabilities.isSupported(llmProvider: .anthropic) == false)
        #expect(capabilities.isSupported(llmProvider: .openAI) == true)
        #expect(capabilities.isSupported(llmProvider: .ollama) == false)
        #expect(capabilities.isSupported(llmProvider: .llamaCpp) == false)
        #expect(capabilities.isSupported(llmProvider: .gemini) == true)
        #expect(capabilities.isSupported(transcriptionProvider: .gemini) == true)
        #expect(capabilities.isSupported(transcriptionProvider: .localWhisper) == false)
        #expect(capabilities.isSupported(transcriptionProvider: .openAI) == true)
#endif
    }

    @Test func providerPlatformSupportExtensions() {
#if os(macOS)
        #expect(LLMProviderID.anthropic.isSupportedOnCurrentPlatform == true)
        #expect(LLMProviderID.openAI.isSupportedOnCurrentPlatform == true)
        #expect(LLMProviderID.ollama.isSupportedOnCurrentPlatform == true)
        #expect(LLMProviderID.llamaCpp.isSupportedOnCurrentPlatform == true)
        #expect(LLMProviderID.mock.isSupportedOnCurrentPlatform == true)
        #expect(LLMProviderID.gemini.isSupportedOnCurrentPlatform == true)

        #expect(TranscriptionProviderID.openAI.isSupportedOnCurrentPlatform == true)
        #expect(TranscriptionProviderID.gemini.isSupportedOnCurrentPlatform == true)
        #expect(TranscriptionProviderID.localWhisper.isSupportedOnCurrentPlatform == true)
        #expect(TranscriptionProviderID.mock.isSupportedOnCurrentPlatform == true)
#elseif os(iOS)
        #expect(LLMProviderID.anthropic.isSupportedOnCurrentPlatform == false)
        #expect(LLMProviderID.openAI.isSupportedOnCurrentPlatform == true)
        #expect(LLMProviderID.ollama.isSupportedOnCurrentPlatform == false)
        #expect(LLMProviderID.llamaCpp.isSupportedOnCurrentPlatform == false)
        #expect(LLMProviderID.mock.isSupportedOnCurrentPlatform == true)
        #expect(LLMProviderID.gemini.isSupportedOnCurrentPlatform == true)

        #expect(TranscriptionProviderID.openAI.isSupportedOnCurrentPlatform == true)
        #expect(TranscriptionProviderID.gemini.isSupportedOnCurrentPlatform == true)
        #expect(TranscriptionProviderID.localWhisper.isSupportedOnCurrentPlatform == false)
        #expect(TranscriptionProviderID.mock.isSupportedOnCurrentPlatform == true)

        #expect(LLMProviderID.currentPlatformSelectable.contains(.openAI))
        #expect(!LLMProviderID.currentPlatformSelectable.contains(.anthropic))
        #expect(!LLMProviderID.currentPlatformSelectable.contains(.ollama))
        #expect(TranscriptionProviderID.currentPlatformSelectable.contains(.openAI))
        #expect(!TranscriptionProviderID.currentPlatformSelectable.contains(.localWhisper))
#endif
    }

    @Test @MainActor func unavailableLLMProviderThrowsTypedError() async {
        let provider = UnavailableLLMProvider(providerID: .anthropic)
        #expect(provider.id == .anthropic)
        #expect(provider.displayName == LLMProviderID.anthropic.title)

        let transcript = Transcript()
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 5, text: "Test transcript")]
        let config = SummaryConfiguration()

        do {
            _ = try await provider.generateSummary(transcript: transcript, configuration: config)
            #expect(Bool(false), "Should have thrown")
        } catch let error as LLMError {
            switch error {
            case .providerUnavailable(let name):
                #expect(name == LLMProviderID.anthropic.title)
            default:
                #expect(Bool(false), "Unexpected error: \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected non-LLM error: \(error)")
        }

        do {
            _ = try await provider.streamChat(messages: [], context: ChatContext(recordingTitle: "Test", transcript: transcript))
            #expect(Bool(false), "Should have thrown")
        } catch let error as LLMError {
            switch error {
            case .providerUnavailable(let name):
                #expect(name == LLMProviderID.anthropic.title)
            default:
                #expect(Bool(false), "Unexpected error: \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected non-LLM error: \(error)")
        }
    }
}
