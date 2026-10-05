import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor @Suite(.serialized)
struct M166LargeProjectMeasurementTests {
    private struct Resolver: LLMProviderResolving {
        func resolve() -> any LLMProvider { MockLLMProvider() }
        func chatSettings() -> LLMGenerationSettings { .init(maxOutputTokens: 1024) }
    }

    @Test func largeProjectRetrievalContextAndHistoryMeasurements() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let project = Project(name: "M16.6 deterministic large project")
        context.insert(project)

        for recordingIndex in 0..<20 {
            let recording = Recording(title: "Lecture \(recordingIndex + 1)", audioFileName: "", originalFileName: "lecture.m4a", duration: 3600)
            let transcript = Transcript()
            transcript.segments = (0..<8).map { index in
                let topic = recordingIndex == 0
                    ? "copy_from_user validates a user pointer and copies bytes into a kernel buffer"
                    : "lecture \(recordingIndex + 1) discusses paging virtual memory and process scheduling"
                return TranscriptSegment(position: index, startTime: Double(index * 60), endTime: Double(index * 60 + 45), text: "\(topic). Segment \(index + 1).")
            }
            recording.transcript = transcript; recording.project = project; context.insert(recording)
        }
        for index in 0..<30 {
            let type: RecordingSourceType = index < 10 ? .pdf : (index < 20 ? .document : .image)
            let source = RecordingSource(type: type, displayName: "Reference \(index + 1)", originalFilename: "reference.\(type == .pdf ? "pdf" : type == .image ? "png" : "md")", localFileReference: "managed", status: .ready)
            source.project = project
            source.textUnits = try (0..<3).map { page in
                let text: String
                if index == 0 { text = "Assignment page 23 explains kernel buffer validation for copy_from_user." }
                else { text = "Reference \(index + 1), section \(page + 1): paging, virtual memory, memory safety and project notes." }
                let locator: SourceLocator = type == .pdf ? .pdf(pageIndex: page + (index == 0 ? 22 : 0)) : type == .image ? .image(region: nil) : .document(section: "Section \(page + 1)", start: 0, end: text.count)
                return try SourceTextUnit(position: page, text: text, origin: type == .image ? .ocr : .nativeText, locator: locator)
            }
            context.insert(source)
        }

        let session = try SwiftDataChatRepository(context: context).ensureProjectSession(for: project)
        for index in 0..<250 {
            let role: ChatRole = index.isMultiple(of: 2) ? .user : .assistant
            let message = ChatMessage(role: role, text: role == .user ? "Compare this point with lecture notes." : "## Prepared answer\n\nThe retrieved material describes memory safety and project evidence.", createdAt: Date(timeIntervalSince1970: Double(index)))
            message.session = session; context.insert(message)
        }
        try context.save()

        let clock = ContinuousClock()
        var openTimes: [Duration] = []
        var preparedMessages = 0
        var markdownBlocks = 0
        var markdownPreparation = Duration.zero
        for _ in 0..<5 {
            let start = clock.now
            let model = ProjectChatViewModel(project: project, resolver: Resolver(), retrieval: RetrievalService())
            model.attach(context: context)
            let presentations = try #require(model.session).orderedMessages.map(ChatMessagePresentation.init)
            let preparation = start.duration(to: clock.now)
            openTimes.append(preparation)
            preparedMessages = presentations.count
            let markdownStart = clock.now
            markdownBlocks = presentations.suffix(125).count { _ in true }
            for _ in 0..<markdownBlocks {
                _ = MarkdownDocument("## Prepared answer\n\nThe retrieved material describes memory safety and project evidence.\n\n- Verify the source.")
            }
            markdownPreparation = markdownStart.duration(to: clock.now)
        }

        let service = RetrievalService()
        let cases = [
            ("recording", "copy_from_user user pointer kernel buffer", true, false),
            ("PDF", "assignment page 23 copy_from_user kernel buffer", false, true),
            ("mixed", "copy_from_user kernel buffer user pointer", true, true),
            ("irrelevant", "quasar bluebird acetone 98431", false, false)
        ]
        var reports: [String] = []
        for (name, query, expectsAudio, expectsPDF) in cases {
            var samples: [Duration] = []
            var selected = 0
            var estimate = 0
            var indexed = 0
            var provenanceIsValid = true
            for _ in 0..<5 {
                let start = clock.now
                let result = try await service.retrieve(query: query, scope: .project(project.id), context: context)
                samples.append(start.duration(to: clock.now))
                selected = result.context.entries.count
                indexed = result.statistics.documentCount
                estimate = result.context.estimatedTokenCount
                let types = Set(result.context.entries.map(\.document.chunk.sourceType))
                let hasAudio = types.contains(.audio)
                let hasPDF = result.context.entries.contains { entry in
                    entry.document.chunk.sourceType == .pdf && {
                        if case .pdf(let page) = entry.document.chunk.locator { return page == 22 }
                        return false
                    }()
                }
                provenanceIsValid = (!expectsAudio || hasAudio) && (!expectsPDF || hasPDF) && result.context.entries.allSatisfy { entry in
                    entry.document.projectID == project.id && !entry.document.unitIDs.isEmpty
                }
                if name == "recording" { #expect(hasAudio) }
                if name == "PDF" { #expect(hasPDF) }
                if name == "mixed" { #expect(hasAudio && result.context.entries.contains { $0.document.chunk.sourceType == .pdf }) }
                if name == "irrelevant" { #expect(result.context.entries.isEmpty) }
            }
            let sorted = samples.sorted { $0 < $1 }
            let median = sorted[sorted.count / 2]
            let constructionStart = clock.now
            let last = try await service.retrieve(query: query, scope: .project(project.id), context: context)
            let json = try ProjectChatPrompt.evidence(last.context)
            let settings = LLMGenerationSettings(maxOutputTokens: 1024)
            let budget = try ProjectChatBudget(contextWindow: 8192, settings: settings, question: query)
            let history = budget.history((0..<250).map { index in .init(role: index.isMultiple(of: 2) ? .user : .assistant, content: "Prepared deterministic project history message \(index).") })
            let prompt = ProjectChatPrompt.prompt(evidence: json, history: history, settings: settings)
            let contextBuild = constructionStart.duration(to: clock.now)
            let promptTokens = TranscriptTokenEstimator.estimate(prompt.systemInstructions) + prompt.messages.reduce(0) { $0 + ProjectChatBudget.tokens($1) }
            // Reuse this exact large mixed corpus against the native local provider's smaller window.
            let localBudget = try ProjectChatBudget(contextWindow: 4096, settings: settings, question: query)
            var localOptions = RetrievalOptions(); localOptions.maximumTokens = localBudget.evidenceBudget
            let localResult = try await service.retrieve(query: query, scope: .project(project.id), context: context, options: localOptions)
            let localPrompt = ProjectChatPrompt.prompt(evidence: try ProjectChatPrompt.evidence(localResult.context),
                history: [.init(role: .user, content: query)], settings: settings)
            let localRequest = try LocalLLMProvider.request(instructions: localPrompt.systemInstructions, messages: localPrompt.messages, kind: .chat, settings: settings)
            #expect(TranscriptTokenEstimator.estimate(localRequest.instructions + localRequest.data) + 1024 + 512 <= 4096)
            #expect(localResult.context.entries.allSatisfy { $0.document.projectID == project.id })
            reports.append("\(name): first \(samples.first!), median \(median), indexed documents \(indexed), selected chunks \(selected), assembled tokens \(estimate), provider prompt estimate \(promptTokens), context JSON+budget+prompt preparation \(contextBuild), provenance \(provenanceIsValid)")
        }
        let sortedOpen = openTimes.sorted { $0 < $1 }
#if os(iOS)
        let environment = "iOS Simulator test runner"
#else
        let environment = "macOS test runner"
#endif
        print("M16.6 \(environment) fixture: 20 recordings / 160 transcript segments / 30 sources (10 PDF, 10 Markdown/text, 10 OCR image) / 250 chat messages. Project attach first \(openTimes.first!), representative median \(sortedOpen[sortedOpen.count / 2]); 250-message presentation snapshot \(preparedMessages) rows; Markdown preparation \(markdownBlocks) assistant documents took \(markdownPreparation). Retrieval/context: \(reports.joined(separator: "; "))")
        #expect(preparedMessages == 250)
        #expect(openTimes.count == 5)
        #expect(markdownBlocks == 125)
    }
}
