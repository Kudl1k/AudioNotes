import Foundation

actor ChatGPTResponsesClient {
    private let baseURL = URL(string: "https://api.openai.com/v1/responses")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generateStructuredSummary(
        accessToken: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        schema: [String: Any],
        settings: LLMGenerationSettings? = nil,
        images: [LLMImageInput] = [],
        timeout: TimeInterval = 120
    ) async throws -> OpenAISummaryResponseDTO {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var userContent: Any = userPrompt
        if !images.isEmpty {
            guard LLMInputCapabilities.known(model: model, provider: .openAI).supportsImageInput else { throw LLMError.invalidResponse }
            var parts: [[String: Any]] = [["type": "input_text", "text": userPrompt]]
            for image in images {
                parts.append(["type": "input_text", "text": "Visual source chunk ID: " + image.chunkID.uuidString])
                parts.append(["type": "input_image", "image_url": image.dataURL, "detail": "high"])
            }
            userContent = parts
        }
        var requestBody: [String: Any] = [
            "model": model,
            "instructions": systemPrompt,
            "input": [
                [
                    "role": "user",
                    "content": userContent
                ]
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "structured_summary",
                    "strict": true,
                    "schema": schema
                ]
            ],
            // ChatGPT-plan requests must not be persisted by the Responses API.
            "store": false,
            "stream": true
        ]

        var capabilities = LLMModelCapabilities.capabilities(for: model, provider: .openAI)
        // The ChatGPT-plan endpoint rejects max_output_tokens even though the
        // corresponding OpenAI API model may support it.
        capabilities.supportsMaxOutputTokens = false
        let sanitized = settings?.sanitized(for: capabilities)

        if let maxTokens = sanitized?.maxOutputTokens {
            requestBody["max_output_tokens"] = maxTokens
        }
        if let effort = sanitized?.reasoningEffort {
            requestBody["reasoning"] = ["effort": effort.rawValue]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        DebugLogService.shared.info(
            subsystem: "ChatGPTResponsesClient",
            message: "Sending streaming summary request: model=\(model), prompt length=\(userPrompt.count)"
        )

        let (asyncBytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.network(code: URLError(.badServerResponse).errorCode)
        }

        if !(200...299).contains(httpResponse.statusCode) {
            try await handleHTTPError(statusCode: httpResponse.statusCode, bytes: asyncBytes)
        }

        var accumulatedText = ""
        var reportedUsage: GenerationUsage?
        var completed = false
        var eventCount = 0

        for try await line in asyncBytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            eventCount += 1
            let type = json["type"] as? String

            if type == "response.output_text.delta" {
                if let delta = json["delta"] as? String {
                    accumulatedText.append(delta)
                }
            } else if type == "response.completed" {
                reportedUsage = ResponsesTokenUsage.from(event: json)
                completed = true
                break
            } else if type == "response.failed" {
                reportedUsage = ResponsesTokenUsage.from(event: json)
                do { try handleStreamFailed(data: data, json: json) }
                catch { throw ProviderUsageError.preserving(error, usage: reportedUsage) }
            }
        }

        DebugLogService.shared.info(
            subsystem: "ChatGPTResponsesClient",
            message: "Provider response could not be processed"
        )

        guard completed || !accumulatedText.isEmpty else {
            DebugLogService.shared.error(
                subsystem: "ChatGPTResponsesClient",
                message: "Stream ended without response.completed or output text"
            )
            throw LLMError.invalidResponse
        }

        guard let summaryData = accumulatedText.data(using: .utf8) else {
            throw LLMError.invalidResponse
        }

        do {
            var decoded = try JSONDecoder().decode(OpenAISummaryResponseDTO.self, from: summaryData)
            decoded.reportedUsage = reportedUsage
            DebugLogService.shared.info(
                subsystem: "ChatGPTResponsesClient",
                message: "Summary parsed successfully (overview length: \(decoded.overview.count))"
            )
            return decoded
        } catch {
            DebugLogService.shared.error(
                subsystem: "ChatGPTResponsesClient",
                message: "Provider response could not be processed"
            )
            throw ProviderUsageError.preserving(LLMError.invalidResponse, usage: reportedUsage)
        }
    }

    func streamChat(
        accessToken: String,
        model: String,
        prompt: FormattedChatPrompt,
        segments: [TranscriptSegmentSnapshot],
        sourceChunks: [SourceChunk] = [],
        settings: LLMGenerationSettings? = nil,
        timeout: TimeInterval = 120
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var inputMessages: [[String: Any]] = prompt.messages.map { msg in
            ["role": msg.role == .assistant ? "assistant" : "user", "content": msg.content]
        }
        if !prompt.images.isEmpty, let index = prompt.messages.lastIndex(where: { $0.role == .user }) {
            guard LLMInputCapabilities.known(model: model, provider: .openAI).supportsImageInput else { throw LLMError.invalidResponse }
            var parts: [[String: Any]] = [["type": "input_text", "text": prompt.messages[index].content]]
            for image in prompt.images {
                parts.append(["type": "input_text", "text": "Visual source chunk ID: " + image.chunkID.uuidString])
                parts.append(["type": "input_image", "image_url": image.dataURL, "detail": "high"])
            }
            inputMessages[index]["content"] = parts
        }

        var requestBody: [String: Any] = [
            "model": model,
            "instructions": prompt.systemInstructions,
            "input": inputMessages,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "chat_response",
                    "strict": true,
                    "schema": StreamingJSONAnswerParser.chatSchema()
                ]
            ],
            // Keep the plan-backed path consistent for both summaries and chat.
            "store": false,
            "stream": true
        ]

        var capabilities = LLMModelCapabilities.capabilities(for: model, provider: .openAI)
        capabilities.supportsMaxOutputTokens = false
        let sanitized = settings?.sanitized(for: capabilities)

        if let maxTokens = sanitized?.maxOutputTokens {
            requestBody["max_output_tokens"] = maxTokens
        }
        if let effort = sanitized?.reasoningEffort {
            requestBody["reasoning"] = ["effort": effort.rawValue]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        DebugLogService.shared.info(
            subsystem: "ChatGPTResponsesClient",
            message: "Sending streaming chat request: model=\(model), messages=\(inputMessages.count)"
        )

        let (asyncBytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.network(code: URLError(.badServerResponse).errorCode)
        }

        if !(200...299).contains(httpResponse.statusCode) {
            try await handleHTTPError(statusCode: httpResponse.statusCode, bytes: asyncBytes)
        }

        let resolver = TranscriptReferenceResolver()

        return AsyncThrowingStream { continuation in
            let streamTask = Task {
                do {
                    let parser = StreamingJSONAnswerParser()
                    var reportedUsage: GenerationUsage?

                    for try await line in asyncBytes.lines {
                        try Task.checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }

                        let type = json["type"] as? String
                        if type == "response.output_text.delta" {
                            if let delta = json["delta"] as? String,
                               let parsedDelta = parser.append(chunk: delta) {
                                continuation.yield(.textDelta(parsedDelta))
                            }
                        } else if type == "response.completed" {
                            reportedUsage = ResponsesTokenUsage.from(event: json)
                            if let reportedUsage { continuation.yield(.usage(reportedUsage)) }
                            break
                        } else if type == "response.failed" {
                            reportedUsage = ResponsesTokenUsage.from(event: json)
                            if let reportedUsage { continuation.yield(.usage(reportedUsage)) }
                            try handleStreamFailed(data: data, json: json)
                        }
                    }

                    let dto = parser.finish()
                    let validatedRefs = resolver.resolve(segmentIDs: dto.referenceSegmentIDs, against: segments)
                    if !validatedRefs.isEmpty {
                        continuation.yield(.references(validatedRefs))
                    }
                    let sourceRefs = SourceReferenceResolver().resolve(chunkIDs: dto.referenceSegmentIDs, against: sourceChunks)
                    let response = LLMChatResponse(content: dto.answer, references: validatedRefs, usage: reportedUsage, modelID: model, sourceReferences: sourceRefs)
                    continuation.yield(.completed(response))
                    continuation.finish()
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { @Sendable _ in streamTask.cancel() }
        }
    }

    private func handleHTTPError(statusCode: Int, bytes: URLSession.AsyncBytes) async throws {
        var errorData = Data()
        for try await byte in bytes {
            errorData.append(byte)
            if errorData.count > 65536 { break }
        }

        let errorBody = String(data: errorData, encoding: .utf8) ?? ""
        DebugLogService.shared.error(
            subsystem: "ChatGPTResponsesClient",
            message: "Provider HTTP request rejected"
        )

        var extractedMessage: String?
        if let jsonObject = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any] {
            let errorDict = jsonObject["error"] as? [String: Any]
            let code = (errorDict?["code"] as? String) ?? (jsonObject["code"] as? String)
            if code == "subscription_sharing_usage_limit_exceeded" || code?.contains("usage_limit") == true {
                throw LLMError.chatGPTUsageLimitExceeded(url: "https://chatgpt.com")
            }
            if let detail = jsonObject["detail"] as? String {
                extractedMessage = detail
            } else if let msg = errorDict?["message"] as? String {
                extractedMessage = msg
            } else if let msg = jsonObject["message"] as? String {
                extractedMessage = msg
            }
        }

        switch statusCode {
        case 401:
            throw LLMError.invalidAuthentication
        case 403:
            throw LLMError.accessDenied
        case 429:
            throw LLMError.rateLimited
        case 500...599:
            throw LLMError.server(status: statusCode)
        default:
            let message = extractedMessage ?? errorBody
            throw LLMError.rejected(status: statusCode, message: message.isEmpty ? nil : message)
        }
    }

    private func handleStreamFailed(data: Data, json: [String: Any]) throws {
        let resp = json["response"] as? [String: Any]
        let errorDict = (resp?["error"] as? [String: Any]) ?? (json["error"] as? [String: Any])
        let code = errorDict?["code"] as? String
        let msg = errorDict?["message"] as? String ?? "Stream response failed."

        DebugLogService.shared.error(
            subsystem: "ChatGPTResponsesClient",
            message: "Provider stream failed"
        )

        if code == "subscription_sharing_usage_limit_exceeded" || code?.contains("usage_limit") == true {
            throw LLMError.chatGPTUsageLimitExceeded(url: "https://chatgpt.com")
        }

        throw LLMError.rejected(status: 500, message: msg)
    }
}
