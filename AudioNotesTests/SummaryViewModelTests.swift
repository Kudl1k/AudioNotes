import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct SummaryViewModelTests {
    private final class FailingLLMProvider: LLMProvider {
        let id: LLMProviderID = .mock
        var displayName: String { "Failing Mock" }

        func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
            throw LLMError.creditBalanceExhausted
        }

        func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
            throw LLMError.creditBalanceExhausted
        }
    }

    private final class DelayedLLMProvider: LLMProvider {
        let id: LLMProviderID = .mock
        var displayName: String { "Delayed Mock" }

        func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return Summary(overview: "Finished", preset: configuration.preset)
        }

        func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
    }

    private struct TestResolver: LLMProviderResolving {
        let provider: any LLMProvider
        func resolve() -> any LLMProvider { provider }
        func resolveChat() -> any LLMProvider { provider }
    }

    @Test func successfulGenerationUpdatesStateAndRepository() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }

        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let repository = SwiftDataSummaryRepository(context: context)

        let recording = Recording(title: "Meeting", audioFileName: "rec.m4a", originalFileName: "rec.m4a", duration: 15)
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Important conversation")
        ]
        recording.transcript = transcript

        let viewModel = SummaryViewModel(
            recording: recording,
            resolver: TestResolver(provider: MockLLMProvider())
        )

        #expect(viewModel.state == .idle)

        let task = viewModel.generateSummary(using: repository)
        _ = await task?.result

        #expect(viewModel.state == .completed)
        #expect(recording.summary?.overview.isEmpty == false)
        #expect(recording.summary?.title.isEmpty == false)
        #expect(recording.summary != nil)
    }

    @Test func failureShowsErrorMessage() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }

        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let repository = SwiftDataSummaryRepository(context: context)

        let recording = Recording(title: "Meeting", audioFileName: "rec.m4a", originalFileName: "rec.m4a", duration: 15)
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Something")
        ]
        recording.transcript = transcript

        let viewModel = SummaryViewModel(
            recording: recording,
            resolver: TestResolver(provider: FailingLLMProvider())
        )

        let task = viewModel.generateSummary(using: repository)
        _ = await task?.result

        if case .failed(let message) = viewModel.state {
            #expect(message.contains("balance"))
        } else {
            Issue.record("Expected failed state")
        }
    }

    @Test func cancelStopsInFlightGeneration() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }

        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = container.mainContext
        let repository = SwiftDataSummaryRepository(context: context)

        let recording = Recording(title: "Meeting", audioFileName: "rec.m4a", originalFileName: "rec.m4a", duration: 15)
        let transcript = Transcript()
        transcript.segments = [
            TranscriptSegment(position: 0, startTime: 0, endTime: 10, text: "Something")
        ]
        recording.transcript = transcript

        let viewModel = SummaryViewModel(
            recording: recording,
            resolver: TestResolver(provider: DelayedLLMProvider())
        )

        let task = viewModel.generateSummary(using: repository)

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(viewModel.state.isGenerating)

        viewModel.cancelGeneration()
        _ = await task?.result

        #expect(viewModel.state == .cancelled || viewModel.state == .idle)
        #expect(recording.summary == nil)
    }
}
