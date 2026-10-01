import Foundation
import PDFKit
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct SourceWorkflowTests {
    @Test func multiSourceSummaryChatAndBothExportsShareValidatedLocations() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer()
        let context = ModelContext(container)
        let recording = try multiSourceFixture()
        context.insert(recording); try context.save()
        let resolver = FixedLLMProviderResolver(provider: MockLLMProvider(delayNanoseconds: 0))
        let summary = SummaryViewModel(recording: recording, resolver: resolver)
        let task = try #require(summary.generateSummary(using: SwiftDataSummaryRepository(context: context)))
        await task.value
        #expect(summary.state == .completed)
        #expect(recording.summary?.sourceReferences.isEmpty == false)
        let chat = ChatViewModel(recording: recording, resolver: resolver)
        chat.attachStorage(SwiftDataChatRepository(context: context))
        chat.selectedSourceIDs = Set(recording.sources.filter { $0.type == .pdf }.map(\.id))
        chat.inputText = "Explain module_init"
        chat.sendMessage()
        for _ in 0..<300 {
            if !chat.isGenerating { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chat.generationState == .completed)
        let answer = try #require(chat.session?.orderedMessages.last)
        #expect(answer.sourceReferences.count == 1)
        #expect(answer.sourceReferences.first?.locator == .pdf(pageIndex: 17))
        #expect(answer.references.isEmpty)
        let generation = try #require(recording.generationRecords.first { $0.featureRaw == "chat" })
        let ids = try JSONDecoder().decode([UUID].self, from: #require(generation.selectedSourceIDsData))
        #expect(ids.count == 1)
        #expect(generation.usageCost.status == .free)
        let content = ExportContentBuilder.build(from: recording)
        let options = ExportOptions(includeSummary: true, includeTranscript: true, includeChat: true)
        let markdown = MarkdownExporter().export(content: content, options: options)
        #expect(markdown.contains("## Sources"))
        #expect(markdown.contains("Slides · p. 18"))
        let pdf = try #require(PDFDocument(data: PDFExporter().export(content: content, options: options)))
        #expect(pdf.string?.contains("Slides · p. 18") == true)
        for id in RecordingContextSnapshot(recording: recording).chunks.flatMap({ [$0.id, $0.sourceID] }) {
            #expect(!markdown.contains(id.uuidString))
            #expect(!(pdf.string?.contains(id.uuidString) ?? false))
        }
    }
    @Test func newAudioOnlySummariesUseAuthoritativeSourceIDs() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = try multiSourceFixture()
        recording.sources = recording.sources.filter(\.isPrimaryAudio)
        context.insert(recording); try context.save()
        let model = SummaryViewModel(recording: recording, resolver: FixedLLMProviderResolver(provider: MockLLMProvider(delayNanoseconds: 0)))
        #expect(model.usesUnifiedContext)
        let task = try #require(model.generateSummary(using: SwiftDataSummaryRepository(context: context)))
        await task.value
        #expect(model.state == .completed)
        let reference = try #require(recording.summary?.sourceReferences.first)
        #expect(reference.sourceID == recording.id)
        if case .audio(let segmentIDs, let start, _) = reference.locator {
            #expect(start == 60)
            #expect(segmentIDs == recording.transcript?.segments.map(\.id))
        } else { Issue.record("Expected audio authority") }
    }

    @Test func summaryIDsResolveAuthoritativePagesAndNeverCreateModelTimestampLinks() throws {
        let recording = try multiSourceFixture()
        let chunk = try #require(RecordingContextSnapshot(recording: recording).chunks.first { $0.sourceType == .pdf })
        let summary = Summary(overview: "Evidence " + chunk.id.uuidString, decisions: [.init(text: "Decision", timestamp: 999)])
        SourceSummaryContext(chunks: [chunk]).resolve(summary, ids: [chunk.id.uuidString, UUID().uuidString, chunk.id.uuidString])
        #expect(summary.sourceReferences.count == 1)
        #expect(summary.sourceReferences.first?.locator == .pdf(pageIndex: 17))
        #expect(summary.decisions.first?.timestamp == nil)
        #expect(!summary.overview.contains(chunk.id.uuidString))
    }
    @Test func cancellationDuringLocalOCRLeavesRecoverableSourceWithoutCloudUsage() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let container = try workspace.storage.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let recording = Recording(title: "Workspace", audioFileName: "", originalFileName: "", duration: 0)
        context.insert(recording)
        let file = workspace.root.appending(path: "image.png")
        try writeSourceTestImage(sourceTestImage(text: "OCR"), to: file, type: "public.png")
        let model = SourcesViewModel(recording: recording, storage: workspace.storage, processor: NativeSourceProcessingService(ocr: WaitingOCR()))
        await model.importURLs([file], context: context)
        let source = try #require(recording.sources.first)
        #expect(source.status == .processing)
        model.cancel(source)
        await model.waitForProcessing()
        #expect(source.status == .failed)
        #expect(!source.isContextReady)
        #expect(recording.generationRecords.isEmpty)
        #expect(FileManager.default.fileExists(atPath: workspace.storage.sourceURL(source).path))
    }
}

private struct WaitingOCR: SourceOCR {
    func recognize(_ image: CGImage) async throws -> [RecognizedSourceText] {
        try await Task.sleep(for: .seconds(30))
        return []
    }
}
