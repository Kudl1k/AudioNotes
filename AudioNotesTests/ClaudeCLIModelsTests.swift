import Foundation
import Synchronization
import Testing
@testable import AudioNotes

private final class ClaudeModelsRunner: ClaudeCLIRunning, Sendable {
    struct Call: Sendable { var arguments: [String]; var input: Data }
    let calls = Mutex<[Call]>([])
    let auth: String
    init(auth: String = "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\"}") { self.auth = auth }
    func run(executable: String, arguments: [String], input: Data, systemPrompt: String?) -> AsyncThrowingStream<Data, Error> {
        calls.withLock { $0.append(Call(arguments: arguments, input: input)) }
        let auth = self.auth
        return AsyncThrowingStream { continuation in
            do {
                if arguments == ["auth", "status"] {
                    continuation.yield(Data(auth.utf8))
                } else {
                    let request = try #require(JSONSerialization.jsonObject(with: input) as? [String: Any])
                    let id = try #require(request["request_id"] as? String)
                    let data = try JSONSerialization.data(withJSONObject: [
                        "type": "control_response", "response": ["subtype": "success", "request_id": id,
                        "response": ["models": [
                            ["value": "sonnet", "displayName": "Sonnet test", "description": "Efficient", "resolvedModel": "claude-sonnet-test"],
                            ["value": "opus", "displayName": "Opus test"]
                        ]]]
                    ])
                    // Reads can split JSON anywhere, including inside a UTF-8 character.
                    for byte in data { continuation.yield(Data([byte])) }
                    continuation.yield(Data([10]))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

private struct ClaudeModelsFixtureClient: ClaudeCLIModelsFetching {
    let models: [ClaudeCLIModel]
    var failure: ClaudeCLIError? = nil
    func fetchModels(executable: String) async throws -> [ClaudeCLIModel] {
        if let failure { throw failure }
        return models
    }
}

@MainActor
struct ClaudeCLIModelsTests {
    @Test func discoversModelsUsingInitializationOnlyWithoutInference() async throws {
        let runner = ClaudeModelsRunner()
        let models = try await ClaudeCLIClient(runner: runner).models()
        #expect(models.map(\.id) == ["sonnet", "opus"])
        #expect(models.first?.displayName == "Sonnet test")
        #expect(models.first?.description == "Efficient")
        #expect(models.first?.resolvedModel == "claude-sonnet-test")
        let calls = runner.calls.withLock { $0 }
        #expect(calls.count == 2)
        let request = try #require(JSONSerialization.jsonObject(with: calls[1].input) as? [String: Any])
        #expect(request["type"] as? String == "control_request")
        #expect((request["request"] as? [String: String])?["subtype"] == "initialize")
        #expect(request["message"] == nil)
        #expect(!calls[1].arguments.contains("--model"))
        #expect(!calls[1].arguments.contains("--json-schema"))
        #expect(calls[1].arguments.contains("--safe-mode"))
        #expect(calls[1].arguments.contains("--no-session-persistence"))
        #expect(calls[1].arguments.contains("--strict-mcp-config"))
    }

    @Test func discoveryRequiresAccountLoginWithoutUsingAnAPIKey() async {
        let runner = ClaudeModelsRunner(auth: "{\"loggedIn\":true,\"authMethod\":\"api_key\",\"apiProvider\":\"firstParty\"}")
        await #expect(throws: ClaudeCLIError.unsupportedAuthentication) { _ = try await ClaudeCLIClient(runner: runner).models() }
        #expect(runner.calls.withLock { $0.count } == 1)
    }

    @Test func parserCorrelatesRequestsDeduplicatesAndIgnoresUnknownCapabilities() throws {
        let fixture = """
        {"type":"system","subtype":"init"}
        {"type":"control_response","response":{"subtype":"success","request_id":"other","response":{"models":[{"value":"wrong","displayName":"Wrong"}]}}}
        {"type":"control_response","response":{"subtype":"success","request_id":"expected","response":{"models":[{"value":"sonnet","displayName":"Sonnet","supportsEffort":true},{"value":"sonnet","displayName":"Duplicate"},{"value":"","displayName":"Invalid"},{"value":"bad model","displayName":"Invalid"},{"value":"custom-id"}]}}}
        """
        let models = try ClaudeCLIClient.parseModels(Data(fixture.utf8), requestID: "expected")
        #expect(models.map(\.id) == ["sonnet", "custom-id"])
        #expect(models.last?.displayName == "custom-id")
    }

    @Test func rejectsMissingEmptyMalformedAndFailedResponses() throws {
        for fixture in [
            "not json",
            "{\"type\":\"system\"}",
            "{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"test\"}}",
            "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"test\",\"response\":{\"models\":[]}}}"
        ] {
            #expect(throws: (any Error).self) { _ = try ClaudeCLIClient.parseModels(Data(fixture.utf8), requestID: "test") }
        }
    }

    @Test func modelRefreshCachesNamesAndPreservesBothSelections() async throws {
        let name = "ClaudeModels-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let config = LLMConfiguration(defaults: defaults)
        config.summaryClaudeModel = "custom-old-model"
        config.chatClaudeModel = "opus"
        let models = [ClaudeCLIModel(id: "sonnet", displayName: "Sonnet", resolvedModel: "claude-sonnet-test")]
        let settings = ProviderSettingsViewModel(credentials: MockCredentialStore(), llmConfig: config,
                                                 claudeModelsClient: ClaudeModelsFixtureClient(models: models))
        await settings.fetchClaudeModels()
        #expect(!settings.isFetchingClaudeModels)
        #expect(settings.claudeModelsError == nil)
        #expect(config.cachedClaudeModels == models)
        #expect(config.summaryClaudeModel == "custom-old-model")
        #expect(config.chatClaudeModel == "opus")
        #expect(LLMConfiguration(defaults: defaults).cachedClaudeModels == models)
        #expect(ClaudeCLIModel.options(models, preserving: "custom-old-model").first?.id == "custom-old-model")
        #expect(ClaudeCLIModel.options(models, preserving: "sonnet") == models)
        #expect(ClaudeCLIModel.options(models, preserving: "claude-sonnet-test").first?.displayName == "Sonnet (saved selection)")
        config.claudeExecutablePath = "/different/claude"
        #expect(config.cachedClaudeModels.isEmpty)
        #expect(LLMConfiguration(defaults: defaults).cachedClaudeModels.isEmpty)
    }

    @Test func failureKeepsCachedModelsAndExistingSelections() async throws {
        let name = "ClaudeModelsFailure-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let config = LLMConfiguration(defaults: defaults)
        let cached = [ClaudeCLIModel(id: "sonnet", displayName: "Cached Sonnet")]
        config.cachedClaudeModels = cached
        let settings = ProviderSettingsViewModel(credentials: MockCredentialStore(), llmConfig: config,
                                                 claudeModelsClient: ClaudeModelsFixtureClient(models: [], failure: .timedOut))
        await settings.fetchClaudeModels()
        #expect(!settings.isFetchingClaudeModels)
        #expect(settings.claudeModelsError == ClaudeCLIError.timedOut.localizedDescription)
        #expect(config.cachedClaudeModels == cached)
        #expect(config.summaryClaudeModel == "sonnet")
    }
}
