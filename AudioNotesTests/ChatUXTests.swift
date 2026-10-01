import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct ChatUXTests {

    private struct TestResolver: LLMProviderResolving {
        let provider: any LLMProvider
        func resolve() -> any LLMProvider { provider }
        func resolveChat() -> any LLMProvider { provider }
    }

    private final class DelayedMockChatProvider: LLMProvider {
        let id: LLMProviderID = .mock
        var displayName: String { "Delayed Mock" }

        var continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation?

        func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
            Summary(overview: "Overview", preset: configuration.preset)
        }

        func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                self.continuation = continuation
            }
        }
    }

    private func setupViewModel(provider: any LLMProvider) throws -> (ChatViewModel, Recording, ModelContainer) {
        let schema = Schema([
            Recording.self,
            Transcript.self,
            TranscriptSegment.self,
            Summary.self,
            ChatSession.self,
            ChatMessage.self,
            AIPreset.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext
        let repo = SwiftDataChatRepository(context: context)

        let recording = Recording(title: "UX Test", audioFileName: "audio.m4a", originalFileName: "audio.m4a", duration: 30)
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Welcome to the test.")
        ]
        recording.transcript = transcript
        context.insert(recording)
        try context.save()

        let viewModel = ChatViewModel(recording: recording, resolver: TestResolver(provider: provider))
        viewModel.attachStorage(repo)
        return (viewModel, recording, container)
    }

    @Test func rapidSendAndRetryDoNotAppendOrReplaceActiveWork() throws {
        let (model, _, container) = try setupViewModel(provider: DelayedMockChatProvider())
        defer { model.stopGeneration(); _ = container }
        model.inputText = "First question"
        model.sendMessage()
        model.inputText = "Keep this draft"
        model.sendMessage()
        model.retry()
        model.sendSuggestedPrompt("Replace draft?")
        #expect(model.inputText == "Keep this draft")
        #expect(model.session?.messages.count == 1)
        #expect(model.generationState == .waitingForFirstToken)
    }

    @Test func closedStreamWithoutFinalResponseFailsAndAllowsRetry() async throws {
        let provider = DelayedMockChatProvider()
        let (model, _, container) = try setupViewModel(provider: provider)
        defer { model.stopGeneration(); _ = container }
        model.inputText = "Question"
        model.sendMessage()
        for _ in 0..<200 where provider.continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        let stream = try #require(provider.continuation)
        stream.yield(.textDelta("Partial"))
        stream.finish()
        for _ in 0..<200 where model.isGenerating { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.isGenerating)
        #expect(model.canRetry)
        #expect(model.lastError != nil)
        #expect(model.session?.messages.count == 1)
        #expect(model.streamingDraft == nil)
    }

    @Test func followUpBatchesTokensAndStopPreservesAllConsumedText() async throws {
        let provider = DelayedMockChatProvider()
        let (model, _, container) = try setupViewModel(provider: provider)
        defer { model.stopGeneration(); _ = container }

        model.inputText = "First question"
        model.sendMessage()
        for _ in 0..<100 where provider.continuation == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let first = try #require(provider.continuation)
        first.yield(.completed(LLMChatResponse(content: "Existing **answer**")))
        first.finish()
        for _ in 0..<100 where model.isGenerating {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.generationState == .completed)

        provider.continuation = nil
        model.inputText = "Follow-up question"
        model.sendMessage()
        for _ in 0..<100 where provider.continuation == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let second = try #require(provider.continuation)
        second.yield(.textDelta("Start"))
        for _ in 0..<100 where model.streamingDraft == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.streamingDraft == "Start")
        for _ in 0..<200 { second.yield(.textDelta(" token")) }
        // A reference event is a barrier proving all preceding deltas were consumed.
        let segment = try #require(model.streamingSegments.first)
        second.yield(.references([TranscriptReference(segmentID: segment.id, startTime: 0)]))
        for _ in 0..<100 where model.streamingReferences.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!model.streamingReferences.isEmpty)
        // The 80 ms publisher may fire while parallel suites consume these deltas.
        // Stopping must preserve all consumed text regardless of the last rendered batch.
        #expect(model.streamingDraft?.hasPrefix("Start") == true)
        model.stopGeneration()
        second.finish()
        let messages = model.session?.orderedMessages ?? []
        #expect(messages.count == 4)
        #expect(messages[1].text == "Existing **answer**")
        #expect(messages.last?.text == "Start" + String(repeating: " token", count: 200))
        #expect(messages.last?.status == .interrupted)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.streamingDraft == nil)
    }

    @Test func batchedDraftPublishesAndCompletionCancelsPendingUpdate() async throws {
        let provider = DelayedMockChatProvider()
        let (model, _, container) = try setupViewModel(provider: provider)
        defer { model.stopGeneration(); _ = container }
        model.inputText = "Question"
        model.sendMessage()
        for _ in 0..<100 where provider.continuation == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let stream = try #require(provider.continuation)
        stream.yield(.textDelta("First"))
        stream.yield(.textDelta(" second"))
        for _ in 0..<100 where model.streamingDraft != "First second" {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.streamingDraft == "First second")
        stream.yield(.textDelta(" final"))
        stream.yield(.completed(LLMChatResponse(content: "First second final")))
        stream.finish()
        for _ in 0..<100 where model.isGenerating {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.generationState == .completed)
        #expect(model.streamingDraft == nil)
        #expect(model.session?.orderedMessages.last?.text == "First second final")
    }

    @Test func firstMessageTransitionsImmediatelyToWaitingForFirstToken() throws {
        let provider = DelayedMockChatProvider()
        let (viewModel, _, container) = try setupViewModel(provider: provider)

        #expect(viewModel.generationState == .idle)
        #expect(viewModel.session?.messages.isEmpty == true)

        viewModel.inputText = "Hello first message!"
        viewModel.sendMessage()

        // 1. User message appended immediately
        let messages = viewModel.session?.orderedMessages ?? []
        #expect(messages.count == 1)
        #expect(messages.first?.text == "Hello first message!")

        // 2. Input cleared immediately
        #expect(viewModel.inputText.isEmpty)

        // 3. State immediately transitions to waitingForFirstToken (never leaving user wondering!)
        #expect(viewModel.generationState == .waitingForFirstToken)
        #expect(viewModel.isGenerating == true)

        // Clean up
        viewModel.stopGeneration()
        _ = container
    }

    @Test func transitionsToStreamingOnFirstTokenAndCompletes() async throws {
        let provider = DelayedMockChatProvider()
        let (viewModel, _, container) = try setupViewModel(provider: provider)

        viewModel.inputText = "What was discussed?"
        viewModel.sendMessage()

        #expect(viewModel.generationState == .waitingForFirstToken)

        // Wait for streamChat to initialize continuation
        var waitCount = 0
        while provider.continuation == nil && waitCount < 50 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waitCount += 1
        }
        let continuation = try #require(provider.continuation)

        // Yield first text token
        continuation.yield(.textDelta("First chunk"))
        var streamWait = 0
        while viewModel.generationState != .streaming && streamWait < 50 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            streamWait += 1
        }

        #expect(viewModel.generationState == .streaming)
        #expect(viewModel.streamingDraft == "First chunk")

        // Complete response
        continuation.yield(.completed(LLMChatResponse(content: "First chunk and final.", references: [])))
        continuation.finish()

        var completeWait = 0
        while viewModel.isGenerating && completeWait < 50 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            completeWait += 1
        }

        #expect(viewModel.generationState == .completed)
        #expect(viewModel.isGenerating == false)
        #expect(viewModel.streamingDraft == nil)

        let messages = viewModel.session?.orderedMessages ?? []
        #expect(messages.count == 2)
        #expect(messages.last?.text == "First chunk and final.")
        _ = container
    }

    @Test func stopBeforeFirstTokenCancelsCleanlyWithoutPartialMessage() async throws {
        let provider = DelayedMockChatProvider()
        let (viewModel, _, container) = try setupViewModel(provider: provider)

        viewModel.inputText = "Question to cancel"
        viewModel.sendMessage()

        #expect(viewModel.generationState == .waitingForFirstToken)
        #expect(viewModel.isGenerating == true)

        // User stops before any token arrives
        viewModel.stopGeneration()

        #expect(viewModel.generationState == .cancelled)
        #expect(viewModel.isGenerating == false)
        #expect(viewModel.streamingDraft == nil)

        // Only the user message should be in history, no incomplete assistant message
        let messages = viewModel.session?.orderedMessages ?? []
        #expect(messages.count == 1)
        #expect(messages.first?.role == .user)
        _ = container
    }

    @Test func failurePreservesHistoryAndEnablesRetry() async throws {
        let provider = DelayedMockChatProvider()
        let (viewModel, _, container) = try setupViewModel(provider: provider)

        viewModel.inputText = "This will fail"
        viewModel.sendMessage()

        #expect(viewModel.generationState == .waitingForFirstToken)

        // Wait for streamChat to initialize continuation
        var waitCount = 0
        while provider.continuation == nil && waitCount < 50 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waitCount += 1
        }
        let continuation = try #require(provider.continuation)

        // Provider fails with error
        continuation.finish(throwing: LLMError.creditBalanceExhausted)

        var failWait = 0
        while viewModel.isGenerating && failWait < 50 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            failWait += 1
        }

        if case .failed = viewModel.generationState {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected state to be failed")
        }

        #expect(viewModel.isGenerating == false)
        #expect(viewModel.canRetry == true)
        #expect(viewModel.lastError != nil)

        // Previous user message remains visible
        let messages = viewModel.session?.orderedMessages ?? []
        #expect(messages.count == 1)
        _ = container
    }
    @Test func streamedMarkdownPersistsCleanAndRevalidatesProviderReferences() async throws {
        let provider = DelayedMockChatProvider()
        let (viewModel, recording, container) = try setupViewModel(provider: provider)
        let segment = try #require(recording.transcript?.orderedSegments.first)
        viewModel.inputText = "Postup?"
        viewModel.sendMessage()
        #expect(viewModel.generationState == .waitingForFirstToken)
        for _ in 0..<50 {
            if provider.continuation != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let continuation = try #require(provider.continuation)
        let chunks = ["## Post", "up\n\n1. Napište ", "`kernelový", " modul`...", "\n\n```c\nmodule_", "init(...);", "\n```"]
        for chunk in chunks { continuation.yield(.textDelta(chunk)) }
        var response = LLMChatResponse(content: "placeholder")
        // Simulate a custom provider assigning raw content after construction.
        response.content = chunks.joined() + " 【\(segment.id)】【53?】 4:5651:46"
        response.references = [
            TranscriptReference(segmentID: segment.id, startTime: 9999),
            TranscriptReference(segmentID: segment.id, startTime: 9999),
            TranscriptReference(segmentID: UUID(), startTime: 1)
        ]
        continuation.yield(.completed(response))
        continuation.finish()
        for _ in 0..<50 {
            if !viewModel.isGenerating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let message = try #require(viewModel.session?.orderedMessages.last)
        #expect(message.role == .assistant)
        #expect(message.text == chunks.joined())
        #expect(message.references.count == 1)
        #expect(message.references[0].startTime == segment.startTime)
        #expect(viewModel.generationState == .completed)
        let reloaded = try ModelContext(container).fetch(FetchDescriptor<ChatMessage>())
        #expect(reloaded.first(where: { $0.role == .assistant })?.text == chunks.joined())
    }

}
