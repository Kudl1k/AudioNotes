import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor @Suite(.serialized)
struct ProjectChatPerformanceTests {
    private final class Provider: LLMProvider {
        let id: LLMProviderID = .mock
        let displayName = "Offline stress fixture"
        var inputCapabilities: LLMInputCapabilities { .init(contextWindowTokens: 8192) }
        var executionLocation: ProviderExecutionLocation { .local }
        var billingKind: BillingKind { .local }
        var promptTokens = 0
        var historyCount = 0
        var contextSources = 0
        func generateSummary(transcript: Transcript, configuration: SummaryConfiguration) async throws -> Summary { throw LLMError.invalidResponse }
        func streamChat(messages: [LLMChatMessage], context: ChatContext) async throws -> AsyncThrowingStream<ChatStreamEvent, Error> {
            let prompt = try ChatContextBuilder().buildPrompt(context: context, history: messages)
            promptTokens = TranscriptTokenEstimator.estimate(prompt.systemInstructions) + prompt.messages.reduce(0) { $0 + ProjectChatBudget.tokens($1) }
            historyCount = messages.count; contextSources = Set(context.sourceChunks?.map(\.sourceID) ?? []).count
            let refs = SourceReferenceResolver().resolve(chunkIDs: ["S1"], against: context.sourceChunks ?? [])
            return AsyncThrowingStream { continuation in
                continuation.yield(.textDelta("Grounded fixture response"))
                continuation.yield(.completed(.init(content: "Grounded fixture response", sourceReferences: refs)))
                continuation.finish()
            }
        }
    }
    private struct Resolver: LLMProviderResolving {
        let provider: any LLMProvider
        func resolve() -> any LLMProvider { provider }
        func chatSettings() -> LLMGenerationSettings { .init(maxOutputTokens: 2048) }
    }

    // Swift Testing runs unrelated suites concurrently. Massive SwiftData faulting on the
    // UI actor would invalidate existing short polling deadlines; run this fixture alone.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUDIONOTES_PROJECT_CHAT_STRESS"] == "1"))
    func hundredHourProjectTwoHundredSourcesAndLongChatUseBoundedEvidence() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let project = Project(name: "100-hour synthetic project"); context.insert(project)
        for hour in 0..<100 {
            let recording = Recording(title: "Lecture \(hour)", audioFileName: "", originalFileName: "lecture.m4a", duration: 3600)
            let transcript = Transcript()
            transcript.segments = (0..<360).map { position in
                TranscriptSegment(position: position, startTime: Double(position * 10), endTime: Double(position * 10 + 10),
                    text: "Lecture \(hour) section \(position). " + (hour % 4 == 0 ? "character device registration major minor cdev_add cleanup" : "paging memory semaphores processes") + String(repeating: " Local fixture explanation.", count: 8))
            }
            recording.transcript = transcript; recording.project = project; context.insert(recording)
        }
        for index in 0..<200 {
            let source = RecordingSource(type: .pdf, displayName: "Slides \(index)", originalFilename: "slides.pdf", localFileReference: "original.pdf", status: .ready)
            source.textUnits = (0..<20).map { page in
                try! SourceTextUnit(position: page, text: "Character device registration major minor cdev_add cleanup. " + String(repeating: "Synthetic page text. ", count: 30), origin: .nativeText, locator: .pdf(pageIndex: page))
            }
            source.project = project; context.insert(source)
        }
        let repository = SwiftDataChatRepository(context: context)
        let session = try repository.ensureProjectSession(for: project)
        let previousGeneration = GenerationRecord(feature: .chat, provider: .mock, model: nil, presetName: nil, outputLength: .medium, settings: nil, project: project)
        previousGeneration.selectedSourceIDsData = try JSONEncoder().encode(Array(ProjectChatSelection().sourceIDs(in: project)))
        context.insert(previousGeneration)
        for index in 0..<250 {
            let message = ChatMessage(role: index % 2 == 0 ? .user : .assistant, text: String(repeating: "Prior character device discussion. ", count: 60), createdAt: Date(timeIntervalSince1970: Double(index)))
            if message.role == .assistant { message.generationID = previousGeneration.id }
            message.session = session; context.insert(message)
        }
        try context.save()
        let provider = Provider(), clock = ContinuousClock()
        let openStart = clock.now
        let model = ProjectChatViewModel(project: project, resolver: Resolver(provider: provider), retrieval: RetrievalService())
        model.attach(context: context)
        let open = openStart.duration(to: clock.now)
        model.inputText = "character device registration cleanup"
        let feedbackStart = clock.now
        model.send()
        let feedback = feedbackStart.duration(to: clock.now)
        #expect(model.isGenerating && model.session?.messages.count == 251)
        for _ in 0..<2000 {
            if !model.isGenerating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.state == .completed && model.session?.messages.count == 252)
        #expect(provider.promptTokens + 2048 + 256 <= 8192)
        #expect(provider.historyCount < 20 && provider.contextSources < 20)
        #expect(model.coverage.searchableRecordings == 100 && model.coverage.searchableSources == 200)
        let generation = try #require(project.generationRecords.first { $0.generationStrategy == "project_retrieval" })
        print("M12.3 end-to-end 100h/200-source/250-message fixture: model attach \(open), synchronous send feedback \(feedback), retrieval \(generation.retrievalDurationSeconds ?? -1)s, first token \(generation.firstTokenSeconds ?? -1)s, total \(generation.durationSeconds)s; \(provider.promptTokens) estimated input tokens, \(provider.historyCount) history messages, \(generation.chunkCount) retrieved chunks, \(provider.contextSources) context sources")
        #expect(generation.requests.count == 1 && generation.chunkCount > 0)
    }
}
