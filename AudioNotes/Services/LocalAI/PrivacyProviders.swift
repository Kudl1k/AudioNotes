import Foundation

/// The gate is evaluated at execution, including every hierarchical pass, not just at selection.
@MainActor final class PrivacyLLMProvider: LLMProvider {
    let base: any LLMProvider
    let configuration: LocalAIConfiguration
    var id: LLMProviderID { base.id }
    var displayName: String { base.displayName }
    var modelID: String? { base.modelID }
    var authenticationMethod: ProviderAuthenticationMethod? { base.authenticationMethod }
    var supportsSourceSummaries: Bool { base.supportsSourceSummaries }
    var inputCapabilities: LLMInputCapabilities { base.inputCapabilities }
    var executionLocation: ProviderExecutionLocation { base.executionLocation }
    var billingKind: BillingKind { base.billingKind }
    init(base: any LLMProvider, configuration: LocalAIConfiguration) { self.base = base; self.configuration = configuration }
    func prepareForGeneration() async throws {
        try configuration.policy.validate(executionLocation)
        try await base.prepareForGeneration()
    }
    func summaryRequestFits(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Bool {
        try self.configuration.policy.validate(executionLocation)
        return try await base.summaryRequestFits(context: context, configuration: configuration)
    }
    func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
        try self.configuration.policy.validate(executionLocation)
        return try await base.generateSummary(transcript: transcript, configuration: configuration)
    }
    func generateSourceSummary(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Summary {
        try self.configuration.policy.validate(executionLocation)
        return try await base.generateSourceSummary(context: context, configuration: configuration)
    }
    func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        try configuration.policy.validate(executionLocation)
        return try await base.streamChat(messages: messages, context: context)
    }
}

@MainActor final class PrivacyTranscriptionProvider: TranscriptionProvider {
    let base: any TranscriptionProvider
    let configuration: LocalAIConfiguration
    var displayName: String { base.displayName }
    var isMock: Bool { base.isMock }
    var providerID: String? { base.providerID }
    var modelDisplayName: String? { base.modelDisplayName }
    var modelID: String? { base.modelID }
    var authenticationMethod: ProviderAuthenticationMethod? { base.authenticationMethod }
    var executionLocation: ProviderExecutionLocation { base.executionLocation }
    var billingKind: BillingKind { base.billingKind }
    init(base: any TranscriptionProvider, configuration: LocalAIConfiguration) { self.base = base; self.configuration = configuration }
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress) async throws -> Transcript {
        try configuration.policy.validate(executionLocation)
        return try await base.transcribe(audioURL: audioURL, progress: progress)
    }
    func transcribe(audioURL: URL, progress: @escaping TranscriptionProgress, status: @escaping TranscriptionStatusReporter,
                    usage: @escaping @MainActor (TranscriptionRequestEvent) -> Void) async throws -> Transcript {
        try configuration.policy.validate(executionLocation)
        return try await base.transcribe(audioURL: audioURL, progress: progress, status: status, usage: usage)
    }
}
