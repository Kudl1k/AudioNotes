import Foundation
import Testing
@testable import AudioNotes

@MainActor struct LlamaCppTests {
    @Test func endpointLocationControlsPrivacyAndBilling() throws {
        let defaults = UserDefaults(suiteName: "llama-cpp-" + UUID().uuidString)!
        let config = LocalAIConfiguration(defaults: defaults)
        config.localOnly = true
        let local = LlamaCppLLMProvider(model: "loaded-model", configuration: config)
        #expect(local.id == .llamaCpp)
        #expect(local.executionLocation == .local)
        #expect(local.billingKind == .local)
        try config.policy.validate(local.executionLocation)
        config.llamaCppAddress = "http://192.168.1.22:8080"
        let remote = LlamaCppLLMProvider(model: "loaded-model", configuration: config)
        #expect(remote.executionLocation == .remote)
        #expect(remote.billingKind == .unknown)
        #expect(throws: LocalAIError.privacyBlocked) { try config.policy.validate(remote.executionLocation) }
    }

    @Test func modelAndEndpointPreferencesPersist() {
        let defaults = UserDefaults(suiteName: "llama-cpp-persist-" + UUID().uuidString)!
        let first = LocalAIConfiguration(defaults: defaults)
        first.llamaCppAddress = "http://localhost:9090"
        first.llamaCppModel = "Qwen3-8B"
        let restored = LocalAIConfiguration(defaults: defaults)
        #expect(restored.llamaCppAddress == first.llamaCppAddress)
        #expect(restored.llamaCppModel == "Qwen3-8B")
    }
}
