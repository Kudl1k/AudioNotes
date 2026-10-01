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

    private var preflightResponses: [String: OpenAIStubURLProtocol.Scenario.Response] {
        ["/props": .init(status: 200, data: Data(#"{"default_generation_settings":{"n_ctx":4096}}"#.utf8)),
         "/apply-template": .init(status: 200, data: Data(#"{"prompt":"fixture prompt"}"#.utf8)),
         "/tokenize": .init(status: 200, data: Data(#"{"tokens":[1,2,3]}"#.utf8))]
    }

    @Test func summaryUsesCompatibleSchemaEnvelopeAndPreservesUsage() async throws {
        let content = String(decoding: try JSONEncoder().encode(StructuredSummaryResponse(overview: "Local summary")), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]],
            "usage": ["prompt_tokens": 12, "completion_tokens": 8]
        ])
        let fixture = OpenAINetworkFixture(data: data, responsesByPath: preflightResponses)
        defer { fixture.cleanUp() }
        let config = LocalAIConfiguration(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        config.localOnly = true
        let provider = LlamaCppLLMProvider(model: "loaded-model", configuration: config, session: fixture.session)
        let transcript = Transcript()
        transcript.segments = [.init(position: 0, startTime: 0, endTime: 10, text: "Offline fixture")]
        let summary = try await provider.generateSummary(transcript: transcript, configuration: .init())
        #expect(summary.overview == "Local summary")
        #expect(summary.reportedUsage?.totalTokens == 20)
        let body = try #require(fixture.probe.requestBodies.withLock { $0.last })
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let format = try #require(json["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_object")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["required"] as? [String] == StructuredResponseSchema.summarySchema()["required"] as? [String])
        #expect(format["json_schema"] == nil)
        #expect(json["model"] as? String == "loaded-model")
        #expect(json["max_tokens"] as? Int == 1024)
        #expect(provider.inputCapabilities.contextWindowTokens == 4096)
        #expect(fixture.probe.requests.withLock { $0.filter { $0.url?.path == "/v1/chat/completions" }.count } == 1)
    }

    @Test func badRequestShowsServerReasonWithoutRetrying() async throws {
        let fixture = OpenAINetworkFixture(status: 400, data: Data(#"{"error":{"code":400,"message":"Request exceeds the available context size","type":"invalid_request_error"}}"#.utf8), responsesByPath: preflightResponses)
        defer { fixture.cleanUp() }
        let config = LocalAIConfiguration(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let provider = LlamaCppLLMProvider(model: "loaded-model", configuration: config, session: fixture.session)
        let transcript = Transcript()
        transcript.segments = [.init(position: 0, startTime: 0, endTime: 10, text: "Offline fixture")]
        do {
            _ = try await provider.generateSummary(transcript: transcript, configuration: .init())
            Issue.record("Expected HTTP 400 failure")
        } catch {
            #expect(error as? LocalAIError == .inference("llama.cpp server returned HTTP 400. Request exceeds the available context size"))
        }
        #expect(fixture.probe.requests.withLock { $0.filter { $0.url?.path == "/v1/chat/completions" }.count } == 1)
    }

    @Test func nonJSONBadRequestHasUsefulFallbackWithoutDumpingBody() async throws {
        let fixture = OpenAINetworkFixture(status: 400, data: Data("<html>private proxy response</html>".utf8), responsesByPath: preflightResponses)
        defer { fixture.cleanUp() }
        let config = LocalAIConfiguration(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let provider = LlamaCppLLMProvider(model: "loaded-model", configuration: config, session: fixture.session)
        let transcript = Transcript()
        transcript.segments = [.init(position: 0, startTime: 0, endTime: 10, text: "Offline fixture")]
        do {
            _ = try await provider.generateSummary(transcript: transcript, configuration: .init())
            Issue.record("Expected HTTP 400 failure")
        } catch {
            #expect(error.localizedDescription.contains("server rejected the request"))
            #expect(!error.localizedDescription.contains("private proxy response"))
        }
    }


    @Test func measuredOversizedPromptIsRejectedBeforeInference() async throws {
        var routes = preflightResponses
        routes["/tokenize"] = .init(status: 200, data: try JSONSerialization.data(withJSONObject: ["tokens": Array(repeating: 1, count: 70_483)]))
        let fixture = OpenAINetworkFixture(data: Data(), responsesByPath: routes)
        defer { fixture.cleanUp() }
        let config = LocalAIConfiguration(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let provider = LlamaCppLLMProvider(model: "loaded-model", configuration: config, session: fixture.session)
        let transcript = Transcript()
        transcript.segments = [.init(position: 0, startTime: 0, endTime: 10, text: "Offline fixture")]
        do {
            _ = try await provider.generateSummary(transcript: transcript, configuration: .init())
            Issue.record("Expected context preflight failure")
        } catch {
            #expect(error as? LLMError == .contextTooLarge(approximateTokens: 70_483))
        }
        #expect(fixture.probe.requests.withLock { $0.allSatisfy { $0.url?.path != "/v1/chat/completions" } })
    }

    @Test func remoteMetadataAndPromptSizingAreBlockedUnderLocalOnly() async throws {
        let fixture = OpenAINetworkFixture(data: Data(), responsesByPath: preflightResponses)
        defer { fixture.cleanUp() }
        let config = LocalAIConfiguration(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        config.localOnly = true
        config.llamaCppAddress = "http://192.168.1.22:8080"
        let provider = LlamaCppLLMProvider(model: "loaded-model", configuration: config, session: fixture.session)
        do {
            try await provider.prepareForGeneration()
            Issue.record("Expected privacy rejection")
        } catch { #expect(error as? LocalAIError == .privacyBlocked) }
        #expect(fixture.probe.requests.withLock { $0.isEmpty })
    }


    @Test(arguments: [#"{}"#, #"{"default_generation_settings":{"n_ctx":0}}"#,
                      #"{"default_generation_settings":{"n_ctx":-1}}"#])
    func invalidServerContextDoesNotProceedToInference(properties: String) async throws {
        let fixture = OpenAINetworkFixture(data: Data(properties.utf8))
        defer { fixture.cleanUp() }
        let config = LocalAIConfiguration(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let provider = LlamaCppLLMProvider(model: "loaded-model", configuration: config, session: fixture.session)
        do {
            try await provider.prepareForGeneration()
            Issue.record("Expected invalid context rejection")
        } catch {
            #expect(error.localizedDescription.contains("usable context size"))
        }
        #expect(fixture.probe.requests.withLock { $0.allSatisfy { $0.url?.path == "/props" } })
    }


    @Test(arguments: [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                      .cannotFindHost, .timedOut, .appTransportSecurityRequiresSecureConnection,
                      .serverCertificateUntrusted])
    func metadataTransportErrorPreservesLlamaCppEndpointAndCause(code: URLError.Code) async throws {
        let fixture = OpenAINetworkFixture(data: Data(), error: code)
        defer { fixture.cleanUp() }
        let config = LocalAIConfiguration(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        config.llamaCppAddress = "http://192.168.1.22:11435"
        let provider = LlamaCppLLMProvider(model: "loaded-model", configuration: config, session: fixture.session)
        do {
            try await provider.prepareForGeneration()
            Issue.record("Expected transport rejection")
        } catch {
            let failure = try #require(error as? LocalServerConnectionError)
            #expect(failure.provider == .llamaCpp)
            #expect(failure.code == code)
            #expect(failure.operation == "/props")
            #expect(failure.address == config.llamaCppAddress)
            #expect(!failure.localizedDescription.contains("Ollama"))
            #expect(failure.localizedDescription.contains(String(code.rawValue)))
        }
    }

    @Test(arguments: ["/props", "/apply-template", "/tokenize"])
    func droppedPreflightConnectionRecoversWithoutRepeatingInference(path: String) async throws {
        var routes = preflightResponses
        let response = try #require(routes[path])
        routes[path] = .init(status: response.status, data: response.data,
                             errorsBeforeSuccess: [.networkConnectionLost])
        let content = String(decoding: try JSONEncoder().encode(StructuredSummaryResponse(overview: "Recovered")), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        let fixture = OpenAINetworkFixture(data: data, responsesByPath: routes)
        defer { fixture.cleanUp() }
        let config = LocalAIConfiguration(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let provider = LlamaCppLLMProvider(model: "loaded-model", configuration: config, session: fixture.session)
        let transcript = Transcript()
        transcript.segments = [.init(position: 0, startTime: 0, endTime: 10, text: "Offline fixture")]
        let summary = try await provider.generateSummary(transcript: transcript, configuration: .init())
        #expect(summary.overview == "Recovered")
        #expect(fixture.probe.requests.withLock { $0.filter { $0.url?.path == path }.count } == 2)
        #expect(fixture.probe.requests.withLock { $0.filter { $0.url?.path == "/v1/chat/completions" }.count } == 1)
    }

    @Test(arguments: [URLError.Code.networkConnectionLost, .notConnectedToInternet, .cancelled])
    func persistentTokenizationFailureIsBoundedAndPreventsInference(code: URLError.Code) async throws {
        var routes = preflightResponses
        routes["/tokenize"] = .init(status: 200, data: Data(), errorsBeforeSuccess: [code, code, code])
        let fixture = OpenAINetworkFixture(data: Data(), responsesByPath: routes)
        defer { fixture.cleanUp() }
        let config = LocalAIConfiguration(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let provider = LlamaCppLLMProvider(model: "loaded-model", configuration: config, session: fixture.session)
        let transcript = Transcript()
        transcript.segments = [.init(position: 0, startTime: 0, endTime: 10, text: "Offline fixture")]
        do {
            _ = try await provider.generateSummary(transcript: transcript, configuration: .init())
            Issue.record("Expected tokenization failure")
        } catch {
            if code == .cancelled {
                #expect(error is CancellationError)
            } else {
                let failure = try #require(error as? LocalServerConnectionError)
                #expect(failure.operation == "/tokenize")
                #expect(failure.code == code)
                if code == .networkConnectionLost {
                    #expect(failure.localizedDescription.contains("connection dropped"))
                }
            }
        }
        #expect(fixture.probe.requests.withLock { $0.filter { $0.url?.path == "/tokenize" }.count } == (code == .networkConnectionLost ? 2 : 1))
        #expect(fixture.probe.requests.withLock { $0.allSatisfy { $0.url?.path != "/v1/chat/completions" } })
    }

    @Test func droppedInferenceConnectionIsNotRetried() async throws {
        var routes = preflightResponses
        routes["/v1/chat/completions"] = .init(status: 200, data: Data(), errorsBeforeSuccess: [.networkConnectionLost])
        let fixture = OpenAINetworkFixture(data: Data(), responsesByPath: routes)
        defer { fixture.cleanUp() }
        let config = LocalAIConfiguration(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let provider = LlamaCppLLMProvider(model: "loaded-model", configuration: config, session: fixture.session)
        let transcript = Transcript()
        transcript.segments = [.init(position: 0, startTime: 0, endTime: 10, text: "Offline fixture")]
        do {
            _ = try await provider.generateSummary(transcript: transcript, configuration: .init())
            Issue.record("Expected inference failure")
        } catch {
            let failure = try #require(error as? LocalServerConnectionError)
            #expect(failure.operation == "/v1/chat/completions")
            #expect(failure.code == .networkConnectionLost)
        }
        #expect(fixture.probe.requests.withLock { $0.filter { $0.url?.path == "/v1/chat/completions" }.count } == 1)
    }
}
