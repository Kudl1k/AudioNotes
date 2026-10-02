#if DEBUG && os(macOS)
import Foundation
import SwiftData

/// Opt-in, deterministic UI stress data. Only called inside the isolated fixture scene.
@MainActor enum ChatPresentationFixtures {
    static func prepare(context: ModelContext) throws {
        let recordings = try context.fetch(FetchDescriptor<Recording>())
        for recording in recordings where recording.transcript != nil {
            let session = recording.chatSessions.first ?? ChatSession()
            if session.recording == nil { session.recording = recording; context.insert(session) }
            fill(session, scope: recording.id.uuidString)
        }
        for project in try context.fetch(FetchDescriptor<Project>()) {
            let session = try SwiftDataChatRepository(context: context).ensureProjectSession(for: project)
            fill(session, scope: project.id.uuidString)
        }
        try context.save()
    }

    private static func fill(_ session: ChatSession, scope: String) {
        // Keep existing fixture messages and add enough rows for exactly 500.
        guard session.messages.count < 500 else { return }
        for index in session.messages.count..<500 {
            let message = ChatMessage(id: PerformanceFixtures.id("chat-ui-\(scope)-\(index)"),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: index.isMultiple(of: 2) ? "Explain lifecycle \(index)" : PerformanceFixtures.markdown,
                createdAt: PerformanceFixtures.epoch.addingTimeInterval(Double(index)))
            session.messages.append(message)
        }
    }
}

/// Mock-only slow stream gives native tests time to scroll, Stop and inspect thinking.
@MainActor final class ChatPresentationFixtureProvider: LLMProvider {
    let id = LLMProviderID.mock
    let displayName = "Shared Chat UI Fixture"
    func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary {
        try await MockLLMProvider().generateSummary(transcript: transcript, configuration: configuration)
    }
    func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let base = try await MockLLMProvider(delayNanoseconds: 0).streamChat(messages: messages, context: context)
        var response = LLMChatResponse(content: "")
        for try await event in base {
            if case .completed(let final) = event { response = final }
        }
        let question = messages.last(where: { $0.role == .user })?.content ?? ""
        if question.contains("fixture-error") { throw LLMError.rateLimited }
        response.content += "\n\n" + String(repeating: PerformanceFixtures.markdown, count: 6) + "\n| Topic | Status |\n| --- | --- |\n| Native chat | Ready |\n"
        let final = response
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .seconds(2))
                    let content = Array(final.content)
                    for start in stride(from: 0, to: content.count, by: 160) {
                        try Task.checkCancellation()
                        continuation.yield(.textDelta(String(content[start..<min(start + 160, content.count)])))
                        try await Task.sleep(for: .milliseconds(40))
                    }
                    continuation.yield(.completed(final)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
#endif
