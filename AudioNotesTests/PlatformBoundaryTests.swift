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
        #expect(capabilities.isSupported(llmProvider: .gemini) == false)
        #expect(capabilities.isSupported(transcriptionProvider: .localWhisper) == true)
#endif
    }

    @Test func providerPlatformSupportExtensions() {
        #expect(LLMProviderID.anthropic.isSupportedOnCurrentPlatform == true)
        #expect(LLMProviderID.openAI.isSupportedOnCurrentPlatform == true)
        #expect(LLMProviderID.ollama.isSupportedOnCurrentPlatform == true)
        #expect(LLMProviderID.llamaCpp.isSupportedOnCurrentPlatform == true)
        #expect(LLMProviderID.mock.isSupportedOnCurrentPlatform == true)
        #expect(LLMProviderID.gemini.isSupportedOnCurrentPlatform == false)

        #expect(TranscriptionProviderID.openAI.isSupportedOnCurrentPlatform == true)
        #expect(TranscriptionProviderID.localWhisper.isSupportedOnCurrentPlatform == true)
        #expect(TranscriptionProviderID.mock.isSupportedOnCurrentPlatform == true)
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

    @Test func appStorageLocationsStandardDirectories() {
        let fileManager = FileManager.default
        let appSupport = AppStorageLocations.standardApplicationSupport
        #expect(appSupport.path.contains("Application Support"))

        let temp = AppStorageLocations.temporaryDirectory
        #expect(!temp.path.isEmpty)
        #expect(fileManager.fileExists(atPath: temp.path))

        let caches = AppStorageLocations.cachesDirectory
        #expect(caches.path.contains("Caches"))

        let resolved = AppStorageLocations.applicationSupport()
        #expect(resolved.path.contains("Application Support") || resolved.path.contains("AudioNotes"))
    }

    @Test @MainActor func openSettingsActionExecutionAndEnvironment() {
        var didOpenSettings = false
        let action = OpenSettingsAction {
            didOpenSettings = true
        }

        action()
        #expect(didOpenSettings == true)

        let env = EnvironmentValues()
        #expect(env.openSettingsAction == nil)
    }
}
