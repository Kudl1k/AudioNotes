import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct ChatViewModelTests {

    private struct TestResolver: LLMProviderResolving {
        let provider: any LLMProvider
        func resolve() -> any LLMProvider { provider }
        func resolveChat() -> any LLMProvider { provider }
    }

    private final class FailingChatLLMProvider: LLMProvider {
        let id: LLMProviderID = .mock
        var displayName: String { "Failing Mock" }

        func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
            throw LLMError.creditBalanceExhausted
        }

        func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
            throw LLMError.creditBalanceExhausted
        }
    }

    private final class DelayedChatLLMProvider: LLMProvider {
        let id: LLMProviderID = .mock
        var displayName: String { "Delayed Mock" }

        func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
            return Summary(overview: "Overview", preset: configuration.preset)
        }

        func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    continuation.yield(.textDelta("Thinking about your query..."))
                    do {
                        try await Task.sleep(nanoseconds: 500_000_000)
                        continuation.yield(.completed(LLMChatResponse(content: "Thinking about your query...", references: [])))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: CancellationError())
                    }
                }
                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
        }
    }

    @Test func canSendValidation() throws {
        let recording = Recording(title: "Test", audioFileName: "audio.m4a", originalFileName: "audio.m4a", duration: 10)
        let vm = ChatViewModel(recording: recording, resolver: TestResolver(provider: MockLLMProvider()))

        #expect(vm.canSend == false)

        vm.inputText = "Hello?"
        #expect(vm.canSend == false) // Still no transcript

        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 5, text: "Audio content")
        ]
        recording.transcript = transcript

        #expect(vm.canSend == true)

        vm.inputText = "   "
        #expect(vm.canSend == false)
    }

    @Test func sendsMessageAndPersistsAssistantResponseWithReferences() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }

        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let repository = SwiftDataChatRepository(context: context)

        let recording = Recording(title: "Design Meeting", audioFileName: "audio.m4a", originalFileName: "audio.m4a", duration: 60)
        let transcript = Transcript()
        let seg1 = TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Let's discuss the product architecture.", speaker: "Alice")
        let seg2 = TranscriptSegment(position: 1, startTime: 15, endTime: 30, text: "We decided to proceed with SwiftUI on macOS.", speaker: "Bob")
        transcript.segments = [seg1, seg2]
        recording.transcript = transcript
        context.insert(recording)
        try context.save()

        let viewModel = ChatViewModel(
            recording: recording,
            resolver: TestResolver(provider: MockLLMProvider())
        )
        viewModel.attachStorage(repository)

        #expect(viewModel.session != nil)
        #expect(viewModel.session?.messages.isEmpty == true)

        viewModel.inputText = "What did we decide?"
        viewModel.sendMessage()

        // Input text should be cleared immediately
        #expect(viewModel.inputText.isEmpty)

        // Wait for generation to finish
        var attempts = 0
        while viewModel.isGenerating && attempts < 50 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }

        #expect(viewModel.isGenerating == false)
        #expect(viewModel.streamingDraft == nil)

        let messages = viewModel.session?.orderedMessages ?? []
        #expect(messages.count == 2)

        let userMsg = messages[0]
        #expect(userMsg.role == .user)
        #expect(userMsg.text == "What did we decide?")
        #expect(userMsg.status == .completed)

        let assistantMsg = messages[1]
        #expect(assistantMsg.role == .assistant)
        #expect(assistantMsg.status == .completed)
        #expect(!assistantMsg.text.isEmpty)
        #expect(!assistantMsg.references.isEmpty)
        #expect(assistantMsg.references[0].speaker == "Alice" || assistantMsg.references[0].speaker == "Bob")
    }

    @Test func stoppingGenerationRecordsInterruptedMessage() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }

        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let repository = SwiftDataChatRepository(context: context)

        let recording = Recording(title: "Long Talk", audioFileName: "audio.m4a", originalFileName: "audio.m4a", duration: 120)
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 30, text: "Lengthy discussion")
        ]
        recording.transcript = transcript
        context.insert(recording)
        try context.save()

        let viewModel = ChatViewModel(
            recording: recording,
            resolver: TestResolver(provider: DelayedChatLLMProvider())
        )
        viewModel.attachStorage(repository)

        viewModel.inputText = "Explain in detail"
        viewModel.sendMessage()

        // Wait for first delta to arrive
        var attempts = 0
        while viewModel.streamingDraft == nil && attempts < 50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        #expect(viewModel.isGenerating == true)
        viewModel.stopGeneration()

        #expect(viewModel.isGenerating == false)
        let messages = viewModel.session?.orderedMessages ?? []
        #expect(messages.count == 2)
        if messages.count >= 2 {
            #expect(messages[1].status == .interrupted)
            #expect(messages[1].text == "Thinking about your query...")
        }
    }

    @Test func handlesProviderFailureAndAllowsRetry() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }

        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let repository = SwiftDataChatRepository(context: context)

        let recording = Recording(title: "Failing Talk", audioFileName: "audio.m4a", originalFileName: "audio.m4a", duration: 10)
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 5, text: "Some audio")
        ]
        recording.transcript = transcript
        context.insert(recording)
        try context.save()

        let viewModel = ChatViewModel(
            recording: recording,
            resolver: TestResolver(provider: FailingChatLLMProvider())
        )
        viewModel.attachStorage(repository)

        viewModel.inputText = "Question"
        viewModel.sendMessage()

        var attempts = 0
        while viewModel.isGenerating && attempts < 50 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            attempts += 1
        }

        #expect(viewModel.isGenerating == false)
        #expect(viewModel.lastError != nil)
        #expect(viewModel.canRetry == true)

        let messages = viewModel.session?.orderedMessages ?? []
        #expect(messages.count == 1) // Only user message persisted
    }

    @Test func clearChatDeletesAllMessages() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }

        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let repository = SwiftDataChatRepository(context: context)

        let recording = Recording(title: "Talk", audioFileName: "audio.m4a", originalFileName: "audio.m4a", duration: 10)
        context.insert(recording)
        let session = try repository.getOrCreateSession(for: recording)
        try repository.appendMessage(ChatMessage(role: .user, text: "Hi"), to: session)
        try repository.appendMessage(ChatMessage(role: .assistant, text: "Hello!"), to: session)

        let viewModel = ChatViewModel(
            recording: recording,
            resolver: TestResolver(provider: MockLLMProvider())
        )
        viewModel.attachStorage(repository)

        #expect(viewModel.session?.messages.count == 2)
        viewModel.clearChat()
        #expect(viewModel.session?.messages.isEmpty == true)
    }
}
