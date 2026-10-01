import Foundation

struct OpenAIChatMessage: Encodable, Sendable {
    let role: String
    let content: String

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

struct OpenAILLMRequestDTO: Sendable {
    static func summarySchema() -> [String: Any] { StructuredResponseSchema.summarySchema() }
    static func chatSchema() -> [String: Any] { StructuredResponseSchema.chatSchema() }

    let model: String
    let messages: [OpenAIChatMessage]
    var images: [LLMImageInput] = []
    let settings: LLMGenerationSettings?

    init(
        model: String,
        messages: [OpenAIChatMessage],
        settings: LLMGenerationSettings? = nil
    ) {
        self.model = model
        self.messages = messages
        self.settings = settings
    }

    func encodeToData() throws -> Data {
        let responseFormat: [String: Any] = [
            "type": "json_schema",
            "json_schema": [
                "name": "summary_response",
                "strict": true,
                "schema": Self.summarySchema()
            ]
        ]

        var messagesArray: [[String: Any]] = messages.map { ["role": $0.role, "content": $0.content] }
        if !images.isEmpty, let index = messages.lastIndex(where: { $0.role == "user" }) {
            guard LLMInputCapabilities.known(model: model, provider: .openAI).supportsImageInput else { throw LLMError.invalidResponse }
            var parts: [[String: Any]] = [["type": "text", "text": messages[index].content]]
            for image in images {
                parts.append(["type": "text", "text": "Visual source chunk ID: " + image.chunkID.uuidString])
                parts.append(["type": "image_url", "image_url": ["url": image.dataURL, "detail": "high"]])
            }
            messagesArray[index]["content"] = parts
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": messagesArray,
            "response_format": responseFormat
        ]

        let capabilities = LLMModelCapabilities.capabilities(for: model, provider: .openAI)
        let sanitized = settings?.sanitized(for: capabilities)

        if let maxTokens = sanitized?.maxOutputTokens {
            payload["max_completion_tokens"] = maxTokens
        }
        if let temp = sanitized?.temperature {
            payload["temperature"] = temp
        }
        if let topP = sanitized?.topP {
            payload["top_p"] = topP
        }
        if let effort = sanitized?.reasoningEffort {
            payload["reasoning_effort"] = effort.rawValue
        }

        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    static func encodeChatPayload(
        model: String,
        messages: [OpenAIChatMessage],
        stream: Bool = true,
        settings: LLMGenerationSettings? = nil,
        images: [LLMImageInput] = []
    ) throws -> Data {
        let responseFormat: [String: Any] = [
            "type": "json_schema",
            "json_schema": [
                "name": "chat_response",
                "strict": true,
                "schema": Self.chatSchema()
            ]
        ]
        var messagesArray: [[String: Any]] = messages.map { ["role": $0.role, "content": $0.content] }
        if !images.isEmpty, let index = messages.lastIndex(where: { $0.role == "user" }) {
            guard LLMInputCapabilities.known(model: model, provider: .openAI).supportsImageInput else { throw LLMError.invalidResponse }
            var parts: [[String: Any]] = [["type": "text", "text": messages[index].content]]
            for image in images {
                parts.append(["type": "text", "text": "Visual source chunk ID: " + image.chunkID.uuidString])
                parts.append(["type": "image_url", "image_url": ["url": image.dataURL, "detail": "high"]])
            }
            messagesArray[index]["content"] = parts
        }
        var payload: [String: Any] = [
            "model": model,
            "messages": messagesArray,
            "response_format": responseFormat
        ]
        if stream {
            payload["stream"] = true
            payload["stream_options"] = ["include_usage": true]
        }
        let capabilities = LLMModelCapabilities.capabilities(for: model, provider: .openAI)
        let sanitized = settings?.sanitized(for: capabilities)

        if let maxTokens = sanitized?.maxOutputTokens {
            payload["max_completion_tokens"] = maxTokens
        }
        if let temp = sanitized?.temperature {
            payload["temperature"] = temp
        }
        if let topP = sanitized?.topP {
            payload["top_p"] = topP
        }
        if let effort = sanitized?.reasoningEffort {
            payload["reasoning_effort"] = effort.rawValue
        }

        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }
}

struct OpenAIChatCompletionEnvelope: Codable, Sendable {
    struct Choice: Codable, Sendable {
        struct Message: Codable, Sendable {
            let role: String?
            let content: String?
            let refusal: String?
        }
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    let id: String?
    let choices: [Choice]
    var usage: OpenAITokenUsage?
}
