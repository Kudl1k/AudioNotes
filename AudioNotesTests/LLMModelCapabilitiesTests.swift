import Testing
import Foundation
@testable import AudioNotes

@Suite("LLM Model Capabilities & Settings Tests")
struct LLMModelCapabilitiesTests {

    @Test("GPT-4o capabilities allow temperature and top_p but reject reasoning_effort")
    func testGPT4oCapabilities() {
        let caps = LLMModelCapabilities.capabilities(for: "gpt-4o", provider: .openAI)
        #expect(caps.supportsTemperature == true)
        #expect(caps.supportsTopP == true)
        #expect(caps.supportsMaxOutputTokens == true)
        #expect(caps.supportsReasoningEffort == false)
        #expect(caps.supportsStreaming == true)
        #expect(caps.supportsStructuredOutput == true)
        #expect(caps.minTemperature == 0.0)
        #expect(caps.maxTemperature == 2.0)
    }

    @Test("o3-mini and o1 capabilities reject temperature and top_p but support reasoning_effort")
    func testReasoningModelCapabilities() {
        let capsO3 = LLMModelCapabilities.capabilities(for: "o3-mini", provider: .openAI)
        #expect(capsO3.supportsTemperature == false)
        #expect(capsO3.supportsTopP == false)
        #expect(capsO3.supportsReasoningEffort == true)
        #expect(capsO3.supportsMaxOutputTokens == true)

        let capsO1 = LLMModelCapabilities.capabilities(for: "o1-preview", provider: .openAI)
        #expect(capsO1.supportsTemperature == false)
        #expect(capsO1.supportsTopP == false)
        #expect(capsO1.supportsReasoningEffort == true)
    }

    @Test("Mock provider capabilities support standard sampling parameters")
    func testMockCapabilities() {
        let caps = LLMModelCapabilities.capabilities(for: "mock", provider: .mock)
        #expect(caps.supportsTemperature == true)
        #expect(caps.supportsTopP == true)
        #expect(caps.supportsReasoningEffort == false)
    }

    @Test("Sanitization strips unsupported parameters for reasoning models")
    func testSanitizationForReasoningModels() {
        let caps = LLMModelCapabilities.capabilities(for: "o3-mini", provider: .openAI)
        let settings = LLMGenerationSettings(
            maxOutputTokens: 2048,
            temperature: 0.8,
            topP: 0.9,
            reasoningEffort: .medium
        )

        let sanitized = settings.sanitized(for: caps)
        #expect(sanitized.maxOutputTokens == 2048)
        #expect(sanitized.temperature == nil) // Stripped because unsupported
        #expect(sanitized.topP == nil)        // Stripped because unsupported
        #expect(sanitized.reasoningEffort == .medium)
    }

    @Test("Sanitization strips reasoning effort and clamps temperature for standard models")
    func testSanitizationForStandardModels() {
        let caps = LLMModelCapabilities.capabilities(for: "gpt-4o", provider: .openAI)
        let settings = LLMGenerationSettings(
            maxOutputTokens: 4096,
            temperature: 2.5, // Exceeds 2.0 max
            topP: 1.5,        // Exceeds 1.0 max
            reasoningEffort: .high // Unsupported on gpt-4o
        )

        let sanitized = settings.sanitized(for: caps)
        #expect(sanitized.maxOutputTokens == 4096)
        #expect(sanitized.temperature == 2.0) // Clamped
        #expect(sanitized.topP == 1.0)        // Clamped
        #expect(sanitized.reasoningEffort == nil) // Stripped
    }

    @Test("Request DTO encoding respects model capabilities")
    func testDTOEncodingWithCapabilities() throws {
        // Reasoning model request DTO
        let o3Settings = LLMGenerationSettings(
            maxOutputTokens: 1000,
            temperature: 0.7,
            topP: 0.9,
            reasoningEffort: .high
        )
        let o3DTO = OpenAILLMRequestDTO(
            model: "o3-mini",
            messages: [OpenAIChatMessage(role: "user", content: "test")],
            settings: o3Settings
        )
        let o3Data = try o3DTO.encodeToData()
        let o3Json = try JSONSerialization.jsonObject(with: o3Data) as? [String: Any]
        #expect(o3Json?["max_completion_tokens"] as? Int == 1000)
        #expect(o3Json?["reasoning_effort"] as? String == "high")
        #expect(o3Json?["temperature"] == nil)
        #expect(o3Json?["top_p"] == nil)

        // GPT-4o request DTO
        let gptSettings = LLMGenerationSettings(
            maxOutputTokens: 2000,
            temperature: 0.5,
            topP: 0.95,
            reasoningEffort: .low
        )
        let gptDTO = OpenAILLMRequestDTO(
            model: "gpt-4o",
            messages: [OpenAIChatMessage(role: "user", content: "test")],
            settings: gptSettings
        )
        let gptData = try gptDTO.encodeToData()
        let gptJson = try JSONSerialization.jsonObject(with: gptData) as? [String: Any]
        #expect(gptJson?["max_completion_tokens"] as? Int == 2000)
        #expect(gptJson?["temperature"] as? Double == 0.5)
        #expect(gptJson?["top_p"] as? Double == 0.95)
        #expect(gptJson?["reasoning_effort"] == nil)
    }
}
