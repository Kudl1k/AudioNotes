import Foundation
import Testing
import Synchronization
@testable import AudioNotes

private final class ClaudeFixtureRunner: ClaudeCLIRunning, Sendable {
    struct Call: Sendable { var arguments: [String]; var input: Data; var system: String? }
    let calls = Mutex<[Call]>([])
    let auth: String
    let response: Data
    let failAfterResponse: Bool
    init(auth: String = "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\",\"email\":\"test@example.com\"}", response: Data = Data(), failAfterResponse: Bool = false) {
        self.auth = auth; self.response = response; self.failAfterResponse = failAfterResponse
    }
    func run(executable: String, arguments: [String], input: Data, systemPrompt: String?) -> AsyncThrowingStream<Data, Error> {
        calls.withLock { $0.append(Call(arguments: arguments, input: input, system: systemPrompt)) }
        let data = arguments == ["auth", "status"] ? Data(auth.utf8) : response
        return AsyncThrowingStream { continuation in
            // Split UTF-8 and JSON across arbitrary process reads.
            for byte in data { continuation.yield(Data([byte])) }
            if failAfterResponse && arguments != ["auth", "status"] {
                continuation.finish(throwing: ClaudeCLIError.executionFailed(1))
            } else { continuation.finish() }
        }
    }
}

@Suite(.serialized)
@MainActor
struct ClaudeCLITests {
    private func result(_ output: [String: Any], error: Bool = false) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "type": "result", "subtype": error ? "error_max_turns" : "success", "is_error": error,
            "structured_output": output,
            "usage": ["input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 30, "cache_creation_input_tokens": 40],
            "modelUsage": ["claude-sonnet-test": [:]]
        ])
        data.append(10)
        return data
    }

    @Test func subscriptionLoginIsRequiredAndNeverFallsBackToKeys() async throws {
        for auth in [
            "{\"loggedIn\":false,\"authMethod\":\"claude.ai\",\"apiProvider\":\"firstParty\"}",
            "{\"loggedIn\":true,\"authMethod\":\"api_key\",\"apiProvider\":\"firstParty\"}",
            "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"apiProvider\":\"bedrock\"}"
        ] {
            let runner = ClaudeFixtureRunner(auth: auth)
            let client = ClaudeCLIClient(runner: runner)
            await #expect(throws: ClaudeCLIError.self) {
                _ = try await client.generate(model: "sonnet", system: "rules", input: Data(), schema: "{}")
            }
            #expect(runner.calls.withLock { $0.count } == 1)
        }
    }

    @Test func loginUsesTheCLIWithoutReadingTokens() async throws {
        let runner = ClaudeFixtureRunner()
        let account = try await ClaudeCLIClient(runner: runner).signIn()
        #expect(account.state == .connected)
        #expect(account.authenticationMethod == .claudeCode)
        #expect(runner.calls.withLock { $0.map(\.arguments) } == [["auth", "login"], ["auth", "status"]])
    }

    @Test func chatResolvesOnlyAuthoritativeIDsAndPreservesMarkdown() async throws {
        let transcript = Transcript()
        let segment = TranscriptSegment(position: 0, startTime: 5, endTime: 8, text: "Budget approved.")
        transcript.segments = [segment]
        let runner = ClaudeFixtureRunner(response: try result([
            "answer": "**Approved** — příští týden.",
            "referenceSegmentIDs": [segment.id.uuidString, UUID().uuidString, segment.id.uuidString]
        ]))
        let provider = ClaudeCLILLMProvider(client: ClaudeCLIClient(runner: runner))
        let response = try await provider.chat(messages: [.init(role: .user, content: "What was decided?")],
                                               context: .init(recordingTitle: "Meeting", transcript: transcript))
        #expect(response.content == "**Approved** — příští týden.")
        #expect(response.references.count == 1)
        #expect(response.references.first?.startTime == 5)
        #expect(response.usage?.inputTokens == 10)
        #expect(response.usage?.cachedInputTokens == 30)
        #expect(response.usage?.cacheWriteInputTokens == 40)
        #expect(response.usage?.inputIncludesCachedTokens == false)
        #expect(response.modelID == "claude-sonnet-test")
        #expect(provider.billingKind == .unknown)
        #expect(provider.executionLocation == .cloud)
        let call = try #require(runner.calls.withLock { $0.last })
        #expect(call.arguments.contains("--no-session-persistence"))
        #expect(!call.arguments.contains("--dangerously-skip-permissions"))
        #expect(call.arguments.contains("--safe-mode"))
        #expect(call.system?.contains("Budget approved.") == false)
        #expect(String(decoding: call.input, as: UTF8.self).contains("Budget approved."))
        let messages = try JSONDecoder().decode([LLMChatMessage].self, from: call.input)
        #expect(messages.last?.content == "What was decided?")
    }

    @Test func summaryStripsModelTimestampsAndKeepsReportedUsage() async throws {
        let transcript = Transcript()
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Launch agreed.")]
        let runner = ClaudeFixtureRunner(response: try result([
            "overview": "Launch agreed.", "keyPoints": [], "referenceChunkIDs": [],
            "decisions": [["text": "Launch", "timestampSeconds": 999]], "actionItems": [],
            "openQuestions": [], "importantQuotes": [], "additionalSections": []
        ]))
        let summary = try await ClaudeCLILLMProvider(client: ClaudeCLIClient(runner: runner)).generateSummary(
            transcript: transcript, configuration: .init(preset: .meeting))
        #expect(summary.preset == .meeting)
        #expect(summary.decisions.first?.timestamp == nil)
        #expect(summary.reportedUsage?.outputTokens == 20)
        #expect(summary.modelName == "claude-sonnet-test")
    }

    @Test func sourceSummaryResolvesOnlySelectedChunksAndKeepsSourceDataOutOfInstructions() async throws {
        let recording = try multiSourceFixture()
        let chunks = RecordingContextSnapshot(recording: recording).chunks.filter { $0.sourceType == .pdf }
        let chunk = try #require(chunks.first)
        let runner = ClaudeFixtureRunner(response: try result([
            "overview": "The slides discuss module_init.", "keyPoints": [],
            "referenceChunkIDs": [chunk.id.uuidString, chunk.id.uuidString, UUID().uuidString],
            "decisions": [], "actionItems": [], "openQuestions": [], "importantQuotes": [], "additionalSections": []
        ]))
        let summary = try await ClaudeCLILLMProvider(client: ClaudeCLIClient(runner: runner)).generateSourceSummary(
            context: .init(chunks: chunks), configuration: .init())
        #expect(summary.sourceReferences.count == 1)
        #expect(summary.sourceReferences.first?.locator == .pdf(pageIndex: 17))
        let call = try #require(runner.calls.withLock { $0.last })
        #expect(call.system?.contains("module_init") == false)
        #expect(String(decoding: call.input, as: UTF8.self).contains("module_init"))
        #expect(!String(decoding: call.input, as: UTF8.self).contains("professor"))
    }

    @Test func failedResultRetainsKnownUsage() throws {
        let parser = ClaudeCLIStreamParser()
        do {
            _ = try parser.append(result([:], error: true))
            Issue.record("Expected failed result")
        } catch {
            #expect((error as? ProviderUsageError)?.usage?.outputTokens == 20)
        }
    }

    @Test func processFailureAfterFinalResponseDoesNotLoseReportedUsage() async throws {
        let transcript = Transcript()
        transcript.segments = [TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Connectivity test.")]
        let runner = ClaudeFixtureRunner(response: try result([
            "overview": "Connectivity test.", "keyPoints": [], "referenceChunkIDs": [], "decisions": [], "actionItems": [],
            "openQuestions": [], "importantQuotes": [], "additionalSections": []
        ]), failAfterResponse: true)
        let provider = ClaudeCLILLMProvider(client: ClaudeCLIClient(runner: runner))
        do {
            _ = try await provider.generateSummary(transcript: transcript, configuration: .init())
            Issue.record("Expected process failure")
        } catch {
            #expect((error as? ProviderUsageError)?.usage?.outputTokens == 20)
            #expect((error as? ProviderUsageError)?.underlying as? ClaudeCLIError == .executionFailed(1))
        }
    }

    @Test func ignoresAgentProseAndStreamsOnlyStructuredAnswer() throws {
        let events: [[String: Any]] = [
            ["type": "stream_event", "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "text"]]],
            ["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hidden agent commentary"]]],
            ["type": "stream_event", "event": ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "name": "StructuredOutput"]]],
            ["type": "stream_event", "event": ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"answer\":\"Hello"]]],
            ["type": "stream_event", "event": ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": " world\",\"referenceSegmentIDs\":[]}"]]]
        ]
        let parser = ClaudeCLIStreamParser()
        var answer = ""
        for event in events {
            var data = try JSONSerialization.data(withJSONObject: event); data.append(10)
            for value in try parser.append(data) { if case .answerDelta(let delta) = value { answer += delta } }
        }
        #expect(answer == "Hello world")
    }

    @Test func environmentAndArgumentsDisableKeysRoutingToolsAndPersistence() throws {
        let filtered = ClaudeCLIRunner.environment(["HOME": "/home/test", "PATH": "/bin", "ANTHROPIC_API_KEY": "secret",
            "ANTHROPIC_BASE_URL": "https://elsewhere", "CLAUDE_CODE_OAUTH_TOKEN": "secret", "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_CONFIG_DIR": "/other", "CLAUDECODE": "1"])
        #expect(filtered == ["HOME": "/home/test", "PATH": "/bin"])
        let arguments = ClaudeCLIClient.arguments(model: "opus", schema: "{}")
        #expect(arguments[try #require(arguments.firstIndex(of: "--tools")) + 1] == "")
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--setting-sources"))
        #expect(arguments.contains("--no-session-persistence"))
    }

    @Test func independentModelsPersistAndLocalOnlyBlocksClaude() async throws {
        let name = "ClaudeCLI-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let config = LLMConfiguration(defaults: defaults)
        config.summaryProvider = .anthropic; config.chatProvider = .anthropic
        config.summaryClaudeModel = "opus"; config.chatClaudeModel = "haiku"
        config.claudeExecutablePath = "/custom/claude"
        let reopened = LLMConfiguration(defaults: defaults)
        #expect(reopened.summaryClaudeModel == "opus")
        #expect(reopened.chatClaudeModel == "haiku")
        #expect(reopened.claudeExecutablePath == "/custom/claude")
        #expect(!reopened.summaryCapabilities.supportsTemperature)
        #expect(!reopened.chatCapabilities.supportsMaxOutputTokens)
        let resolver = LLMProviderResolver(configuration: reopened, credentials: MockCredentialStore())
        #expect(resolver.resolve().modelID == "opus")
        #expect(resolver.resolveChat().modelID == "haiku")
        #expect(resolver.resolveSummary(provider: .anthropic, model: "sonnet").modelID == "sonnet")
        reopened.localAI.localOnly = true
        await #expect(throws: LocalAIError.privacyBlocked) {
            _ = try await resolver.resolve().generateSummary(transcript: Transcript(), configuration: .init())
        }
    }

    @Test func missingFinalResultFailsInsteadOfSavingAgentProse() async throws {
        let runner = ClaudeFixtureRunner(response: Data("{\"type\":\"assistant\",\"message\":{}}\n".utf8))
        let stream = try await ClaudeCLIClient(runner: runner).generate(model: "sonnet", system: "rules", input: Data(), schema: "{}")
        await #expect(throws: ClaudeCLIError.invalidResponse) { for try await _ in stream { } }
    }

    @Test func runnerReadsStdinAndCleansTemporaryFiles() async throws {
        let script = try makeScript("#!/bin/sh\n/bin/cat\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let before = try temporaryInvocations()
        var output = Data()
        for try await data in ClaudeCLIRunner().run(executable: script.path, arguments: [], input: Data("řádek\n$()".utf8), systemPrompt: "rules") {
            output.append(data)
        }
        #expect(String(decoding: output, as: UTF8.self) == "řádek\n$()")
        #expect(try temporaryInvocations().subtracting(before).isEmpty)
    }

    @Test func runnerTimeoutTerminatesProcessAndCleansFiles() async throws {
        let script = try makeScript("#!/bin/sh\nexec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let before = try temporaryInvocations()
        let stream = ClaudeCLIRunner(timeout: .milliseconds(100)).run(executable: script.path, arguments: [], input: Data(), systemPrompt: nil)
        await #expect(throws: ClaudeCLIError.timedOut) { for try await _ in stream { } }
        #expect(try temporaryInvocations().subtracting(before).isEmpty)
    }

    @Test func consumerCancellationTerminatesTheRunningCLI() async throws {
        let script = try makeScript("#!/bin/sh\necho ready\nexec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let before = try temporaryInvocations()
        let ready = AsyncStream<Void>.makeStream()
        let task = Task {
            for try await _ in ClaudeCLIRunner().run(executable: script.path, arguments: [], input: Data(), systemPrompt: nil) {
                ready.continuation.yield(())
            }
            try Task.checkCancellation()
        }
        for await _ in ready.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(1200))
        #expect(try temporaryInvocations().subtracting(before).isEmpty)
    }

    @Test func desktopBuildReusesSandboxFilesAndCopiesOnlyNonSecretPreferences() throws {
        let script = try makeScript("")
        let home = script.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = "test.AudioNotes"
        let container = home.appending(path: "Library/Containers/\(id)/Data/Library")
        let support = container.appending(path: "Application Support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("untouched database".utf8).write(to: support.appending(path: "default.store"))
        #expect(AppStorageLocations.applicationSupport(home: home, bundleID: id, fallback: home) == support)
        let prefs = container.appending(path: "Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        let values: [String: Any] = ["ai.localOnly": true, "llm.chat.provider": "anthropic", "llm.summary.provider": "mock",
                                   "llm.secret": "must not copy", "unrelated": "must not copy"]
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: prefs.appending(path: "\(id).plist"))
        let name = "ClaudeMigration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("openAI", forKey: "llm.summary.provider")
        AppStorageLocations.restorePreferences(home: home, bundleID: id, defaults: defaults)
        #expect(defaults.bool(forKey: "ai.localOnly"))
        #expect(defaults.string(forKey: "llm.chat.provider") == "anthropic")
        #expect(defaults.string(forKey: "llm.summary.provider") == "openAI")
        #expect(defaults.object(forKey: "llm.secret") == nil)
        #expect(defaults.object(forKey: "unrelated") == nil)
        defaults.removeObject(forKey: "llm.chat.provider")
        AppStorageLocations.restorePreferences(home: home, bundleID: id, defaults: defaults)
        #expect(defaults.object(forKey: "llm.chat.provider") == nil)
        #expect(try String(contentsOf: support.appending(path: "default.store"), encoding: .utf8) == "untouched database")
    }

    private func makeScript(_ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ClaudeTest-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "claude")
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func temporaryInvocations() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("AudioNotes-Claude-") })
    }
}
