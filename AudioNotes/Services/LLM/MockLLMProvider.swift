import Foundation

@MainActor
final class MockLLMProvider: LLMProvider {
    var supportsSourceSummaries: Bool { true }
    let id: LLMProviderID = .mock
    var displayName: String { "Mock (development)" }
    var delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 400_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    func generateSummary(
        transcript: Transcript,
        configuration: SummaryConfiguration
    ) async throws -> Summary {
        try Task.checkCancellation()

        guard !transcript.segments.isEmpty else {
            throw LLMError.transcriptEmpty
        }

        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }

        try Task.checkCancellation()

        let firstTimestamp = transcript.segments.first?.startTime ?? 0.0
        let midTimestamp = transcript.segments.count > 1
            ? transcript.segments[transcript.segments.count / 2].startTime
            : firstTimestamp
        let lastTimestamp = transcript.segments.last?.startTime ?? midTimestamp

        let keyPoints = [
            KeyPoint(text: "Project requirements and milestones were reviewed in detail."),
            KeyPoint(text: "The audio transcription and LLM abstraction layers operate independently."),
            KeyPoint(text: "All secrets remain isolated in macOS Keychain and are never logged.")
        ]

        let decisions = [
            Decision(text: "Approved proceeding with native SwiftData storage architecture.", timestamp: firstTimestamp),
            Decision(text: "Selected OpenAI as the first cloud provider integration.", timestamp: midTimestamp)
        ]

        let actionItems = [
            ActionItem(text: "Review prompt builder unit test coverage", assignee: "Engineering", dueDate: "Friday", timestamp: midTimestamp),
            ActionItem(text: "Verify timestamp seeking on summary cards", assignee: "QA", dueDate: "Next sprint", timestamp: lastTimestamp)
        ]

        let openQuestions = [
            OpenQuestion(text: "When should long-transcript hierarchical chunking be introduced?", timestamp: midTimestamp)
        ]

        let importantQuotes = [
            ImportantQuote(text: "Summary generation should remain provider-independent.", speaker: "Architecture Team", timestamp: firstTimestamp)
        ]

        var sections: [SummarySection] = []
        switch configuration.preset {
        case .lecture:
            sections = [
                SummarySection(title: "Main Concepts", items: ["Provider Abstraction", "Strict JSON Schema validation", "Isolated Actor Networking"]),
                SummarySection(title: "Study Notes", items: ["Review difference between Whisper-1 and GPT-4o-mini", "Remember never to log credentials"])
            ]
        case .interview:
            sections = [
                SummarySection(title: "Major Topics", items: ["Architecture decisions", "Offline developer experience", "Error recovery"]),
                SummarySection(title: "Follow-up Topics", items: ["Explore local models in future milestones"])
            ]
        case .podcast:
            sections = [
                SummarySection(title: "Topics Discussed", items: ["Building native macOS productivity tools", "Swift 6 Concurrency in practice"]),
                SummarySection(title: "Notable Insights", items: ["Small focused milestones accelerate delivery while preserving architectural clarity"])
            ]
        case .brainstorm:
            sections = [
                SummarySection(title: "Ideas Generated", items: ["Custom prompt overrides", "Automatic audio format detection", "Offline mock toggle"]),
                SummarySection(title: "Potential Next Steps", items: ["Add interactive chat inspector in Milestone 5"])
            ]
        case .custom:
            if let custom = configuration.customInstructions, !custom.isEmpty {
                sections = [
                    SummarySection(title: "Custom Notes", items: ["Generated in accordance with custom instructions: \(custom)"])
                ]
            }
        case .general, .meeting:
            break
        }

        let overview = "This recording covers key technical and architectural decisions for AudioNotes. " +
            "Discussion focused on clean provider abstractions, robust error resilience, and maintaining privacy with Keychain credentials."

        return Summary(
            overview: overview,
            preset: configuration.preset,
            providerName: displayName,
            modelName: "mock-llm-v1",
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions,
            importantQuotes: importantQuotes,
            additionalSections: sections,
            title: "AudioNotes Architecture and Privacy Decisions"
        )
    }

    func generateSourceSummary(context: SourceSummaryContext, configuration: SummaryConfiguration) async throws -> Summary {
        try Task.checkCancellation()
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        let summary = Summary(overview: "Mock multi-source summary (development). " + String((context.chunks.first?.text ?? context.intermediateNotes.first ?? "").prefix(200)),
            preset: configuration.preset, providerName: displayName, modelName: "mock-llm-v1", outputLength: configuration.outputLength,
            title: "Selected Source Highlights")
        context.resolve(summary, ids: context.chunks.prefix(4).map { $0.id.uuidString })
        return summary
    }

    func streamChat(
        messages: [LLMChatMessage],
        context: ChatContext
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        try Task.checkCancellation()

        if let chunks = context.sourceChunks {
            if chunks.isEmpty, context.projectEvidence != nil {
                return AsyncThrowingStream { continuation in
                    let response = LLMChatResponse(content: "I couldn’t find this topic in the searchable project material.")
                    continuation.yield(.textDelta(response.content)); continuation.yield(.completed(response)); continuation.finish()
                }
            }
            guard let first = chunks.first else { throw LLMError.transcriptEmpty }
            let response = LLMChatResponse(content: "Mock response from selected source: " + String(first.text.prefix(200)),
                sourceReferences: SourceReferenceResolver().resolve(chunkIDs: [first.id.uuidString], against: chunks))
            return AsyncThrowingStream { continuation in
                continuation.yield(.textDelta(response.content))
                continuation.yield(.completed(response))
                continuation.finish()
            }
        }
        let segments = context.transcript.orderedSegments
        guard !segments.isEmpty else {
            throw LLMError.transcriptEmpty
        }

        let lastUserMessage = messages.last { $0.role == .user }?.content ?? ""
        let lowercased = lastUserMessage.lowercased()

        // Choose response and reference segment based on content
        let answer: String
        let chosenSegment = segments.first!
        let refResolver = TranscriptReferenceResolver()
        let references = refResolver.resolve(segmentIDs: [chosenSegment.id.uuidString], against: context.transcript)

        if lowercased.contains("decision") {
            answer = "Based on the recording, the team decided to proceed with native SwiftData persistence and use a strict provider abstraction layer."
        } else if lowercased.contains("action") {
            answer = "The main action item mentioned was reviewing prompt builder unit tests and verifying audio timestamp seeking."
        } else if lowercased.contains("point") || lowercased.contains("main") {
            answer = "The primary points discussed were project architecture, privacy preservation with macOS Keychain, and independent provider configuration."
        } else if lowercased.contains("question") {
            answer = "An open question was noted regarding when to introduce hierarchical long-recording chunking."
        } else {
            answer = "According to the transcript, discussion focused on \"\(context.recordingTitle)\", highlighting key architectural principles and implementation details."
        }

        let stepDelay = delayNanoseconds > 0 ? delayNanoseconds / 20 : 0

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Stream answer by words
                    let words = answer.split(separator: " ", omittingEmptySubsequences: false)
                    for (index, word) in words.enumerated() {
                        try Task.checkCancellation()
                        if stepDelay > 0 {
                            try await Task.sleep(nanoseconds: stepDelay)
                        }
                        let textToYield = (index == 0 ? "" : " ") + String(word)
                        continuation.yield(.textDelta(textToYield))
                    }

                    if !references.isEmpty {
                        continuation.yield(.references(references))
                    }

                    let finalResponse = LLMChatResponse(content: answer, references: references)
                    continuation.yield(.completed(finalResponse))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
