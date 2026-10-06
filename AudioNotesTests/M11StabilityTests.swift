import Foundation
import PDFKit
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct M11StabilityTests {
    @Test func chatScrollingRespectsUserIntentAndContentGrowth() {
        var state = ChatScrollState()
        state.positionChanged(nearBottom: false) // Response growth alone does not revoke follow.
        let follows = state.contentArrived()
        #expect(follows)
        state.userScrolling(true)
        state.positionChanged(nearBottom: false)
        state.userScrolling(false)
        let followsAway = state.contentArrived()
        #expect(!followsAway)
        #expect(state.hasUnseenContent)
        state.jumpToLatest()
        let followsAfterJump = state.contentArrived()
        #expect(followsAfterJump)
        #expect(!state.hasUnseenContent)
        state.userScrolling(true)
        state.positionChanged(nearBottom: false)
        state.positionChanged(nearBottom: true)
        state.userScrolling(false)
        #expect(state.followsLatest)
    }

    @Test func eligibilityMatchesDerivedContextIncludingEmptyAndDeselectedSources() throws {
        let recording = try multiSourceFixture()
        let selections: [Set<UUID>?] = [nil, [], [recording.id]] + recording.sources.map { [$0.id] }
        for selected in selections {
            let snapshot = RecordingContextSnapshot(recording: recording, selectedSourceIDs: selected)
            #expect(RecordingContextAvailability.hasContent(recording, selectedSourceIDs: selected) == !snapshot.chunks.isEmpty)
            #expect(RecordingContextAvailability.readySourceIDs(recording, selectedSourceIDs: selected) == snapshot.readySourceIDs)
        }
        recording.transcript?.segments.forEach { $0.text = " \n " }
        recording.sources.removeAll()
        #expect(!RecordingContextAvailability.hasContent(recording))
        let image = RecordingSource(type: .image, displayName: "Empty OCR", originalFilename: "a.png", localFileReference: "a.png", status: .ready)
        recording.sources = [image]
        #expect(RecordingContextAvailability.hasContent(recording))
        image.status = .failed
        #expect(!RecordingContextAvailability.hasContent(recording))
    }

    @Test func backgroundSnapshotIsIdenticalAndPreservesAuthoritativeReferences() async throws {
        let recording = try multiSourceFixture()
        let sync = RecordingContextSnapshot(recording: recording)
        let async = try await RecordingContextSnapshot.load(recording: recording)
        #expect(sync.chunks == async.chunks)
        #expect(sync.readySourceIDs == async.readySourceIDs)
        let reference = try #require(SourceReferenceResolver().resolve(chunkIDs: [sync.chunks[0].id.uuidString], against: sync.chunks).first)
        let index = SourceReferenceIndex(chunks: sync.chunks)
        #expect(index.validate([reference, reference]).count == 1)
        let forged = SourceReference(sourceID: UUID(), chunkID: reference.chunkID, sourceName: "Forged", sourceType: .image, locator: .image(region: nil), excerpt: "Untrusted")
        #expect(index.validate([forged]).isEmpty)
    }

    @Test func recordingOwnedModelsKeepDraftAndSelectionsAcrossNavigation() throws {
        let library = LibraryViewModel()
        let recording = try PerformanceFixtures.recording(.small)
        let other = try PerformanceFixtures.recording(.medium)
        let resolver = FixedLLMProviderResolver(provider: MockLLMProvider())
        let chat = library.chatModel(for: recording, resolver: resolver)
        let summary = library.summaryModel(for: recording, resolver: resolver)
        chat.inputText = "Unsent draft"
        chat.selectedSourceIDs = [recording.id]
        summary.customInstructions = "My instructions"
        _ = library.chatModel(for: other, resolver: resolver)
        _ = library.summaryModel(for: other, resolver: resolver)
        #expect(library.chatModel(for: recording, resolver: resolver) === chat)
        #expect(library.summaryModel(for: recording, resolver: resolver) === summary)
        #expect(chat.inputText == "Unsent draft")
        #expect(chat.selectedSourceIDs == [recording.id])
        #expect(summary.customInstructions == "My instructions")
    }

    @Test func transcriptSearchOrdersAndMatchesSpeakersWithoutChangingIDs() async throws {
        let recording = try PerformanceFixtures.recording(.large)
        let model = TranscriptViewModel()
        await model.load(recording.transcript)
        #expect(model.visibleSegments.count == 2400)
        #expect(model.visibleSegments.first?.position == 0)
        await model.search("Speaker A", debounce: false)
        #expect(model.visibleSegments.count == 480)
        #expect(model.visibleSegments.first?.id == recording.transcript?.orderedSegments.first?.id)
        await model.search("  ", debounce: false)
        #expect(model.visibleSegments.count == 2400)
        await model.search("No matching phrase", debounce: false)
        #expect(model.visibleSegments.isEmpty)
    }

    @Test func nativeBackgroundExportProducesReadablePDFAndMarkdown() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = try PerformanceFixtures.recording(.small)
        let content = ExportContentBuilder.build(from: recording)
        for format in ExportFormat.allCases {
            let url = directory.appending(path: "export." + format.fileExtension)
            try await NativeExportService().write(content: content, options: .init(format: format), to: url)
            if format == .pdf {
                let pdf = try #require(PDFDocument(url: url))
                #expect(pdf.pageCount > 0)
                #expect(pdf.string?.contains(recording.title) == true)
                #expect(pdf.string?.contains("Generated by Soniquill") == true)
            } else { #expect(try String(contentsOf: url, encoding: .utf8).contains(recording.title)) }
        }
    }

    @Test func cancelledExportPreservesExistingFileAndRejectsDuplicateStart() async throws {
        let recording = try PerformanceFixtures.recording(.small)
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".md")
        try Data("Existing export".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = ExportViewModel()
        #expect(model.chooseDestination())
        #expect(!model.chooseDestination())
        let task = try #require(model.export(recording: recording, options: .init(), to: url))
        #expect(model.state == .exporting)
        #expect(model.export(recording: recording, options: .init(), to: url) == nil)
        model.cancel()
        await task.value
        #expect(model.state == .idle)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Existing export")
    }

    @Test func cleanupLoadsAuthoritativeIDsOnlyWhenProseContainsAUUID() {
        let internalID = UUID()
        let ordinaryID = UUID()
        var evaluations = 0
        func ids() -> [UUID] { evaluations += 1; return [internalID] }
        #expect(ChatContentNormalizer.clean("Normal [brackets] and prose.", internalSegmentIDs: ids()) == "Normal [brackets] and prose.")
        #expect(evaluations == 0)
        let cleaned = ChatContentNormalizer.clean("Keep \(ordinaryID); hide \(internalID)", internalSegmentIDs: ids())
        #expect(evaluations == 1)
        #expect(cleaned.contains(ordinaryID.uuidString))
        #expect(!cleaned.contains(internalID.uuidString))
    }

    private struct FailingExport: ExportWriting {
        func write(content: ExportContent, options: ExportOptions, to url: URL) async throws {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    @Test func exportDiskFailureIsRecoverableAndClearsBusyState() async throws {
        let model = ExportViewModel(service: FailingExport())
        let recording = try PerformanceFixtures.recording(.small)
        #expect(model.chooseDestination())
        let task = try #require(model.export(recording: recording, options: .init(), to: URL(fileURLWithPath: "/unused/export.md")))
        await task.value
        #expect(!model.isBusy)
        #expect(model.errorMessage != nil)
        #expect(model.chooseDestination())
        model.cancel()
    }

    private final class FailingChatStore: ChatStoring {
        let session = ChatSession()
        func ensureSession(for recording: Recording) throws -> ChatSession { session }
        func appendMessage(_ message: ChatMessage, to session: ChatSession) throws { throw CocoaError(.fileWriteOutOfSpace) }
        func updateMessage(_ message: ChatMessage, status: ChatMessageStatus, references: [TranscriptReference]) throws { }
        func deleteMessage(_ message: ChatMessage) throws { }
        func clearMessages(in session: ChatSession) throws { }
    }

    @Test func chatPersistenceFailurePreservesUnsentQuestion() throws {
        let recording = try PerformanceFixtures.recording(.small)
        let model = ChatViewModel(recording: recording, resolver: FixedLLMProviderResolver(provider: MockLLMProvider()))
        model.attachStorage(FailingChatStore())
        model.inputText = "Question to preserve"
        model.sendMessage()
        #expect(model.inputText == "Question to preserve")
        #expect(model.session?.messages.isEmpty == true)
        #expect(!model.isGenerating)
        #expect(model.lastError != nil)
    }

    @Test func veryLongMarkdownKeepsCodeAndSemanticBlocksIntact() {
        let code = String(repeating: "let value = 1234567890; ", count: 6000)
        let text = "## Large answer\n\n" + String(repeating: "Paragraph with **bold** and `code`.\n\n", count: 3000) + "```swift\n" + code + "\n```"
        let document = MarkdownDocument(text)
        #expect(document.blocks.count == 3002)
        #expect(document.blocks.last == .code(language: "swift", text: code))
    }

    @Test func cancelledSnapshotDoesNotReturnDerivedContent() async throws {
        let recording = try PerformanceFixtures.recording(.large)
        let task = Task { try await RecordingContextSnapshot.load(recording: recording) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled snapshot unexpectedly returned content")
        } catch is CancellationError { }
    }

    @Test func sourceSearchSupersededByEmptyQueryCannotPublishStaleResults() async throws {
        let recording = try multiSourceFixture()
        let model = SourcesViewModel(recording: recording)
        model.searchQuery = "kernel"
        model.search()
        model.searchQuery = ""
        model.search()
        try await Task.sleep(for: .milliseconds(220))
        #expect(model.searchResults.isEmpty)
    }
}
