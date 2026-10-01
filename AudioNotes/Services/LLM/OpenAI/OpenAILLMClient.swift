import Foundation

final class OpenAILLMClient: @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: configuration)
        }
    }

    func generateSummary(
        prompt: SummaryPrompt,
        model: String,
        apiKey: String,
        settings: LLMGenerationSettings? = nil
    ) async throws -> OpenAISummaryResponseDTO {
        try Task.checkCancellation()

        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let messages = [
            OpenAIChatMessage(role: "system", content: prompt.systemMessage),
            OpenAIChatMessage(role: "user", content: prompt.userMessage)
        ]

        var dto = OpenAILLMRequestDTO(
            model: model,
            messages: messages,
            settings: settings
        )

        dto.images = prompt.images
        request.httpBody = try dto.encodeToData()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: RefuseRedirects())
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw LLMError.network(code: (error as? URLError)?.errorCode ?? URLError.unknown.rawValue)
        }

        guard let http = response as? HTTPURLResponse else {
            DebugLogService.shared.error(subsystem: "OpenAILLMClient", message: "Non-HTTP response")
            throw LLMError.invalidResponse
        }

        DebugLogService.shared.info(
            subsystem: "OpenAILLMClient",
            message: "Response HTTP \(http.statusCode)"
        )

        guard (200..<300).contains(http.statusCode) else {
            DebugLogService.shared.error(
                subsystem: "OpenAILLMClient",
                message: "Provider HTTP request rejected"
            )
            throw Self.mapHTTPError(status: http.statusCode, data: data)
        }

        let envelope: OpenAIChatCompletionEnvelope
        do {
            envelope = try JSONDecoder().decode(OpenAIChatCompletionEnvelope.self, from: data)
        } catch {
            DebugLogService.shared.error(subsystem: "OpenAILLMClient", message: "Failed to decode envelope")
            throw LLMError.invalidResponse
        }

        guard let firstChoice = envelope.choices.first else {
            DebugLogService.shared.error(subsystem: "OpenAILLMClient", message: "No choices returned")
            throw ProviderUsageError.preserving(LLMError.invalidResponse, usage: envelope.usage?.normalized)
        }

        if let refusal = firstChoice.message.refusal, !refusal.isEmpty {
            DebugLogService.shared.warning(subsystem: "OpenAILLMClient", message: "Provider declined the request")
            throw ProviderUsageError.preserving(LLMError.refusal(message: refusal), usage: envelope.usage?.normalized)
        }

        guard let contentString = firstChoice.message.content,
              let contentData = contentString.data(using: .utf8) else {
            DebugLogService.shared.error(subsystem: "OpenAILLMClient", message: "Missing content string")
            throw ProviderUsageError.preserving(LLMError.invalidResponse, usage: envelope.usage?.normalized)
        }

        do {
            var dto = try JSONDecoder().decode(OpenAISummaryResponseDTO.self, from: contentData)
            dto.reportedUsage = envelope.usage?.normalized
            DebugLogService.shared.info(subsystem: "OpenAILLMClient", message: "Summary decoded successfully")
            return dto
        } catch {
            DebugLogService.shared.error(
                subsystem: "OpenAILLMClient",
                message: "Provider response could not be processed"
            )
            throw ProviderUsageError.preserving(LLMError.invalidResponse, usage: envelope.usage?.normalized)
        }
    }

    func streamChat(
        prompt: FormattedChatPrompt,
        model: String,
        apiKey: String,
        segments: [TranscriptSegmentSnapshot],
        sourceChunks: [SourceChunk] = [],
        settings: LLMGenerationSettings? = nil
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        try Task.checkCancellation()

        let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: prompt.systemInstructions)
        ]
        for m in prompt.messages {
            messages.append(OpenAIChatMessage(role: m.role.rawValue, content: m.content))
        }

        request.httpBody = try OpenAILLMRequestDTO.encodeChatPayload(
            model: model,
            messages: messages,
            stream: true,
            settings: settings, images: prompt.images
        )

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: RefuseRedirects())
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw LLMError.network(code: (error as? URLError)?.errorCode ?? URLError.unknown.rawValue)
        }

        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            DebugLogService.shared.error(subsystem: "OpenAILLMClient", message: "Non-HTTP response for chat stream")
            throw LLMError.invalidResponse
        }

        DebugLogService.shared.info(
            subsystem: "OpenAILLMClient",
            message: "Stream HTTP \(http.statusCode)"
        )

        guard (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 65536 { break }
            }
            DebugLogService.shared.error(
                subsystem: "OpenAILLMClient",
                message: "Provider response could not be processed"
            )
            throw Self.mapHTTPError(status: http.statusCode, data: errorData)
        }

        let resolver = TranscriptReferenceResolver()

        return AsyncThrowingStream { continuation in
            let streamTask = Task {
                do {
                    let parser = StreamingJSONAnswerParser()
                    var usage: GenerationUsage?

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8) else { continue }

                        if let envelope = try? JSONDecoder().decode(OpenAIStreamUsage.self, from: data), let reported = envelope.usage {
                            usage = reported.normalized
                            continuation.yield(.usage(reported.normalized))
                        }
                        if let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = rawObject["choices"] as? [[String: Any]],
                           let firstChoice = choices.first {
                            if let delta = firstChoice["delta"] as? [String: Any],
                               let content = delta["content"] as? String {
                                if let answerChunk = parser.append(chunk: content) {
                                    continuation.yield(.textDelta(answerChunk))
                                }
                            }
                        }
                    }

                    let dto = parser.finish()
                    let validatedRefs = resolver.resolve(segmentIDs: dto.referenceSegmentIDs, against: segments)
                    if !validatedRefs.isEmpty {
                        continuation.yield(.references(validatedRefs))
                    }
                    let sourceRefs = SourceReferenceResolver().resolve(chunkIDs: dto.referenceSegmentIDs, against: sourceChunks)
                    let response = LLMChatResponse(content: dto.answer, references: validatedRefs, usage: usage, modelID: model, sourceReferences: sourceRefs)
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

    private static func mapHTTPError(status: Int, data: Data) -> LLMError {
        var message: String?
        var code: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            message = error["message"] as? String
            code = error["code"] as? String
        }

        switch status {
        case 401:
            return .invalidAuthentication
        case 429:
            if code == "credit_balance_exhausted" || code == "insufficient_quota" {
                return .creditBalanceExhausted
            }
            if let msg = message?.lowercased(), msg.contains("quota") || msg.contains("billing") || msg.contains("credit") {
                return .creditBalanceExhausted
            }
            return .rateLimited
        case 500...599:
            return .server(status: status)
        default:
            return .rejected(status: status, message: message)
        }
    }
}
