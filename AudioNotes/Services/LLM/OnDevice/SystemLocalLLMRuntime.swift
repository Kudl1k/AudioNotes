import Foundation
#if os(iOS)
import FoundationModels
#endif

actor SystemLocalLLMRuntime: LocalLLMRunning {
    private var worker: Task<Void, Never>?
    func cancelAndUnload() async {
        let task = worker
        worker = nil
        task?.cancel()
        await task?.value
    }
    func stream(_ request: LocalLLMRequest) async throws -> AsyncThrowingStream<LocalLLMEvent, Error> {
#if os(iOS)
        if #available(iOS 26, *) { return try await nativeStream(request) }
#endif
        throw LLMError.providerUnavailable("On-device language model requires iOS 26 and Apple Intelligence")
    }

#if os(iOS)
    @available(iOS 26, *)
    private func nativeStream(_ request: LocalLLMRequest) async throws -> AsyncThrowingStream<LocalLLMEvent, Error> {
        try Task.checkCancellation()
        guard case .available = SystemLanguageModel.default.availability else {
            throw LocalAIError.inference(Self.availabilityDescription)
        }
        let schema = try GenerationSchema(root: Self.schema(request.kind), dependencies: [])
        let userData = "UNTRUSTED USER MESSAGES JSON DATA:\n" + request.data
        if #available(iOS 26.4, *) {
            let model = SystemLanguageModel.default
            let instructions = try await model.tokenCount(for: Instructions(request.instructions))
            let prompt = try await model.tokenCount(for: userData)
            let structure = try await model.tokenCount(for: schema)
            let total = instructions + prompt + structure + (request.settings.maxOutputTokens ?? 1024) + 128
            guard total <= 4096 else { throw LLMError.contextTooLarge(approximateTokens: total) }
        }
        let session = LanguageModelSession(instructions: request.instructions)
        let options = GenerationOptions(temperature: request.settings.temperature, maximumResponseTokens: request.settings.maxOutputTokens)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var final: GeneratedContent?
                    // The session is request-scoped; no model or private conversation is retained between operations.
                    for try await snapshot in session.streamResponse(to: userData,
                                                                     schema: schema, options: options) {
                        try Task.checkCancellation()
                        final = snapshot.content
                        if case .chat = request.kind, let answer = try? snapshot.content.value(String.self, forProperty: "answer") {
                            continuation.yield(.answerSnapshot(answer))
                        }
                    }
                    try Task.checkCancellation()
                    guard let final, final.isComplete else { throw LLMError.invalidResponse }
                    continuation.yield(.completedJSON(final.jsonString))
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()) }
                    else { continuation.finish(throwing: LocalAIError.inference("On-device processing failed. The model may be unavailable, the context too long, or the request unsupported. Retry or choose another provider.")) }
                }
            }
            worker = task
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    @available(iOS 26, *)
    private static func schema(_ kind: LocalLLMResponseKind) throws -> DynamicGenerationSchema {
        let original = kind == .chat ? StructuredResponseSchema.chatSchema() : StructuredResponseSchema.summarySchema()
        func convert(_ value: [String: Any], name: String) throws -> DynamicGenerationSchema {
            if let alternatives = value["anyOf"] as? [[String: Any]], let nonNull = alternatives.first(where: { $0["type"] as? String != "null" }) {
                return try convert(nonNull, name: name)
            }
            switch value["type"] as? String {
            case "string": return .init(type: String.self)
            case "number": return .init(type: Double.self)
            case "array":
                guard let item = value["items"] as? [String: Any] else { throw LLMError.invalidResponse }
                return .init(arrayOf: try convert(item, name: name + "Item"))
            case "object":
                guard let properties = value["properties"] as? [String: [String: Any]] else { throw LLMError.invalidResponse }
                // Alphabetical order is deterministic, with answer before citation IDs for progressive rendering.
                return .init(name: name, properties: try properties.keys.sorted().map { key in
                    let property = properties[key]!
                    return .init(name: key, description: property["description"] as? String,
                        schema: try convert(property, name: name + key.capitalized), isOptional: property["anyOf"] != nil)
                })
            default: throw LLMError.invalidResponse
            }
        }
        return try convert(original, name: kind == .chat ? "AudioNotesChat" : "AudioNotesSummary")
    }
#endif

    nonisolated static var availabilityDescription: String {
#if os(iOS)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Ready · Managed by Apple Intelligence"
            case .unavailable(.deviceNotEligible): return "Apple Intelligence is not supported on this device."
            case .unavailable(.appleIntelligenceNotEnabled): return "Enable Apple Intelligence in system Settings to prepare the on-device language model."
            case .unavailable(.modelNotReady): return "Apple Intelligence is preparing the model. Check system Settings and try again when ready."
            case .unavailable: return "The on-device language model is unavailable on this device or in this region."
            }
        }
#endif
        return "Requires iOS 26 and a device supporting Apple Intelligence."
    }
}
