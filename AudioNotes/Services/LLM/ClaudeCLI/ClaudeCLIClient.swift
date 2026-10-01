import Foundation

struct ClaudeCLIClient: Sendable {
    let executable: String
    let runner: any ClaudeCLIRunning
    init(executable: String = "", runner: any ClaudeCLIRunning = ClaudeCLIRunner()) {
        self.executable = executable
        self.runner = runner
    }

    func account() async throws -> ProviderAccount {
        let data: Data
        do { data = try await collect(arguments: ["auth", "status"]) }
        catch ClaudeCLIError.executionFailed(1) {
            return ProviderAccount(provider: .anthropic, authenticationMethod: .claudeCode, state: .disconnected)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else { throw ClaudeCLIError.invalidResponse }
        let supported = object["authMethod"] as? String == "claude.ai" && object["apiProvider"] as? String == "firstParty"
        return ProviderAccount(provider: .anthropic, displayName: object["subscriptionType"] as? String,
                               email: object["email"] as? String, authenticationMethod: .claudeCode,
                               state: !loggedIn ? .disconnected : supported ? .connected : .needsReauthentication,
                               capabilities: supported && loggedIn ? [.textGeneration, .modelDiscovery] : [])
    }

    func signIn() async throws -> ProviderAccount {
        _ = try await collect(arguments: ["auth", "login"])
        return try await account()
    }

    func models() async throws -> [ClaudeCLIModel] {
        let account = try await account()
        guard account.state != .disconnected else { throw ClaudeCLIError.notSignedIn }
        guard account.state == .connected else { throw ClaudeCLIError.unsupportedAuthentication }
        try Task.checkCancellation()
        let requestID = UUID().uuidString
        let request: [String: Any] = ["type": "control_request", "request_id": requestID, "request": ["subtype": "initialize"]]
        var input = try JSONSerialization.data(withJSONObject: request)
        input.append(10)
        // Initialize only: no user message or inference is sent. stdin EOF ends the probe.
        let data = try await collect(arguments: ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
                                    + Self.isolationArguments, input: input)
        return try Self.parseModels(data, requestID: requestID)
    }

    static func parseModels(_ data: Data, requestID: String) throws -> [ClaudeCLIModel] {
        for line in data.split(separator: 10) {
            guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { throw ClaudeCLIError.invalidResponse }
            guard object["type"] as? String == "control_response",
                  let response = object["response"] as? [String: Any], response["request_id"] as? String == requestID else { continue }
            guard response["subtype"] as? String == "success",
                  let payload = response["response"] as? [String: Any], let models = payload["models"] as? [[String: Any]] else {
                throw ClaudeCLIError.invalidResponse
            }
            var seen = Set<String>()
            var result: [ClaudeCLIModel] = []
            for model in models {
                guard let id = model["value"] as? String, !id.isEmpty, id.count <= 256, !id.contains(where: \.isWhitespace),
                      seen.insert(id).inserted else { continue }
                let name = (model["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(ClaudeCLIModel(id: id, displayName: name?.isEmpty == false ? name! : id,
                                             description: model["description"] as? String, resolvedModel: model["resolvedModel"] as? String))
            }
            guard !result.isEmpty else { throw ClaudeCLIError.invalidResponse }
            return result
        }
        throw ClaudeCLIError.invalidResponse
    }

    private func collect(arguments: [String], input: Data = Data()) async throws -> Data {
        var result = Data()
        for try await data in runner.run(executable: executable, arguments: arguments, input: input, systemPrompt: nil) {
            try Task.checkCancellation()
            result.append(data)
            guard result.count <= 1_024 * 1_024 else { throw ClaudeCLIError.invalidResponse }
        }
        return result
    }

    static func arguments(model: String, schema: String) -> [String] {
        ["--print", "--model", model, "--output-format", "stream-json", "--verbose", "--include-partial-messages",
         "--json-schema", schema] + isolationArguments
    }

    static var isolationArguments: [String] {
        ["--tools", "", "--disallowedTools", "mcp__*", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
         "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}", "--safe-mode",
         "--disable-slash-commands", "--no-session-persistence"]
    }

    func generate(model: String, system: String, input: Data, schema: String) async throws -> AsyncThrowingStream<ClaudeCLIEvent, Error> {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClaudeCLIError.invalidModel }
        let approximateTokens = (input.count + system.utf8.count) / 4
        guard approximateTokens <= 100_000 else { throw LLMError.contextTooLarge(approximateTokens: approximateTokens) }
        let account = try await account()
        guard account.state != .disconnected else { throw ClaudeCLIError.notSignedIn }
        guard account.state == .connected else { throw ClaudeCLIError.unsupportedAuthentication }
        try Task.checkCancellation()
        let raw = runner.run(executable: executable, arguments: Self.arguments(model: model, schema: schema), input: input, systemPrompt: system)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let parser = ClaudeCLIStreamParser()
                var resultSeen = false
                do {
                    for try await data in raw {
                        try Task.checkCancellation()
                        for event in try parser.append(data) {
                            if case .result = event { resultSeen = true }
                            continuation.yield(event)
                        }
                    }
                    for event in try parser.finish() {
                        if case .result = event { resultSeen = true }
                        continuation.yield(event)
                    }
                    guard resultSeen else { throw ClaudeCLIError.invalidResponse }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

enum ClaudeCLIEvent: Sendable {
    case answerDelta(String)
    case result(ClaudeCLIResult)
}

struct ClaudeCLIResult: Sendable {
    var structuredOutput: Data
    var usage: GenerationUsage?
    var model: String?
}

/// Only the structured-output tool supplies partial answer Markdown. Ordinary agent
/// prose and reasoning are ignored. Final fields always come from structured_output.
final class ClaudeCLIStreamParser {
    private var buffer = Data()
    private var structuredBlock: Int?
    private var answerParser = StreamingJSONAnswerParser()

    func append(_ data: Data) throws -> [ClaudeCLIEvent] {
        buffer.append(data)
        guard buffer.count <= 8 * 1_024 * 1_024 else { throw ClaudeCLIError.invalidResponse }
        var events: [ClaudeCLIEvent] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            events += try parse(line)
        }
        return events
    }

    func finish() throws -> [ClaudeCLIEvent] {
        let remainder = buffer
        buffer.removeAll()
        return try parse(remainder)
    }

    private func parse(_ data: Data) throws -> [ClaudeCLIEvent] {
        guard !data.isEmpty else { return [] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeCLIError.invalidResponse }
        if object["type"] as? String == "stream_event", let event = object["event"] as? [String: Any] {
            let index = event["index"] as? Int
            if event["type"] as? String == "content_block_start",
               let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use",
               block["name"] as? String == "StructuredOutput" {
                structuredBlock = index
                answerParser = StreamingJSONAnswerParser()
            }
            if event["type"] as? String == "content_block_delta", let index, index == structuredBlock,
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "input_json_delta",
               let json = delta["partial_json"] as? String, let answer = answerParser.append(chunk: json) {
                return [.answerDelta(answer)]
            }
            if event["type"] as? String == "content_block_stop", index == structuredBlock { structuredBlock = nil }
        }
        guard object["type"] as? String == "result" else { return [] }
        let usage = Self.usage(object["usage"] as? [String: Any])
        if object["is_error"] as? Bool == true {
            throw ProviderUsageError.preserving(ClaudeCLIError.requestFailed, usage: usage)
        }
        guard object["is_error"] as? Bool != true, object["subtype"] as? String == "success",
              let output = object["structured_output"] as? [String: Any] else {
            throw ProviderUsageError.preserving(ClaudeCLIError.invalidResponse, usage: usage)
        }
        let models = object["modelUsage"] as? [String: Any]
        return [.result(ClaudeCLIResult(structuredOutput: try JSONSerialization.data(withJSONObject: output), usage: usage,
                                      model: models?.count == 1 ? models?.keys.first : nil))]
    }

    private static func usage(_ object: [String: Any]?) -> GenerationUsage? {
        guard let object else { return nil }
        func count(_ key: String) -> Int? {
            guard let value = object[key] as? Int, value >= 0 else { return nil }
            return value
        }
        let input = count("input_tokens"), output = count("output_tokens")
        let read = count("cache_read_input_tokens"), write = count("cache_creation_input_tokens")
        guard input != nil || output != nil || read != nil || write != nil else { return nil }
        let cache = object["cache_creation"] as? [String: Any]
        let duration: Int? = (cache?["ephemeral_1h_input_tokens"] as? Int == write && (write ?? 0) > 0) ? 3600
            : (cache?["ephemeral_5m_input_tokens"] as? Int == write && (write ?? 0) > 0) ? 300 : nil
        let details = object["output_tokens_details"] as? [String: Any]
        return GenerationUsage(inputTokens: input, outputTokens: output,
                               cachedInputTokens: read, reasoningTokens: details?["thinking_tokens"] as? Int,
                               cacheWriteInputTokens: write, cacheWriteDurationSeconds: duration, inputIncludesCachedTokens: false)
    }
}
