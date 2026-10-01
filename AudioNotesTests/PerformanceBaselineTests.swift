import Foundation
import PDFKit
import SwiftData
import Testing
@testable import AudioNotes

@Suite(.serialized)
@MainActor
struct PerformanceBaselineTests {
    @Test func historicalChatCleanupCost() throws {
        let recording = try PerformanceFixtures.recording(.stress)
        let text = PerformanceFixtures.markdown
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<100 {
            #expect(ChatContentNormalizer.clean(text, internalSegmentIDs: recording.transcript?.segments.map(\.id) ?? []) == text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        print("M11 100 historical-message cleanups in stress recording: \(start.duration(to: clock.now))")
    }

    @Test func representativeFixturesAndBaseline() throws {
        for size in PerformanceFixtures.Size.allCases {
            let recording = try PerformanceFixtures.recording(size)
            #expect(recording.transcript?.segments.count == size.segments)
            #expect(recording.chatSessions.first?.messages.count == size.messages)
            let clock = ContinuousClock()
            let start = clock.now
            var count = 0
            for _ in 0..<10 { count += RecordingContextSnapshot(recording: recording).chunks.count }
            print("M11 current \(size.rawValue) 10 full context checks: \(start.duration(to: clock.now)); chunks \(count / 10)")
            #expect(count >= size.segments * 10)
            let eligibilityStart = clock.now
            for _ in 0..<10 { #expect(RecordingContextAvailability.hasContent(recording)) }
            print("M11 after \(size.rawValue) 10 availability checks: \(eligibilityStart.duration(to: clock.now))")
            let snapshotStart = clock.now
            let input = RecordingContextSnapshot.Input(recording: recording, selectedSourceIDs: nil)
            print("M11 after \(size.rawValue) main-actor input copy: \(snapshotStart.duration(to: clock.now))")
            let deriveStart = clock.now
            #expect(RecordingContextSnapshot(input: input).chunks.count == count / 10)
            print("M11 after \(size.rawValue) pure context derivation: \(deriveStart.duration(to: clock.now))")
            let parseStart = clock.now
            for _ in 0..<100 { #expect(!MarkdownDocument(PerformanceFixtures.markdown).blocks.isEmpty) }
            print("M11 current \(size.rawValue) 100 Markdown block parses: \(parseStart.duration(to: clock.now))")
        }
    }
}

@Suite(.serialized)
@MainActor
struct NativePerformanceFixtureTests {
    @Test func nativePDFAndImageAssetsAreUsableAndThumbnailCacheIsBoundedInSize() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pdfURL = directory.appending(path: "slides.pdf")
        let imageURL = directory.appending(path: "board.png")
        let thumbURL = directory.appending(path: "thumbnail.jpg")
        try await Task.detached {
            try PerformanceFixtureAssets.write([
                .init(url: pdfURL, type: .pdf, pages: 100, thumbnailURL: thumbURL),
                .init(url: imageURL, type: .image, pages: 0, thumbnailURL: thumbURL)
            ])
        }.value
        let clock = ContinuousClock()
        let pdfStart = clock.now
        let pdf = try #require(PDFDocument(url: pdfURL))
        #expect(pdf.pageCount == 100)
        #expect(pdf.page(at: 99)?.string?.contains("Page 100") == true)
        print("M11 native 100-page PDF open and last-page text: \(pdfStart.duration(to: clock.now))")
        let loader = SourceImageLoader()
        let decodeStart = clock.now
        let first = try #require(await loader.image(url: imageURL, maximumDimension: 220))
        print("M11 native 12MP image thumbnail cold decode: \(decodeStart.duration(to: clock.now))")
        #expect(max(first.width, first.height) <= 220)
        let hitStart = clock.now
        let second = try #require(await loader.image(url: imageURL, maximumDimension: 220))
        print("M11 native thumbnail cache hit: \(hitStart.duration(to: clock.now))")
        #expect(first === second)
        let corrupt = directory.appending(path: "corrupt.jpg")
        try Data("invalid image bytes".utf8).write(to: corrupt)
        #expect(await loader.image(url: corrupt, maximumDimension: 220) == nil)
        #expect(await loader.image(url: directory.appending(path: "missing.jpg"), maximumDimension: 220) == nil)
    }

    @Test func fiveHundredRecordingFetchAndStressGraphPersistWithoutDataLoss() throws {
        let container = try LibraryStorage().makeContainer(inMemory: true)
        let context = container.mainContext
        for index in 0..<500 {
            context.insert(Recording(id: PerformanceFixtures.id("library-\(index)"), title: "Recording \(index)",
                audioFileName: "", originalFileName: "", duration: 0, importedAt: PerformanceFixtures.epoch))
        }
        let stress = try PerformanceFixtures.recording(.stress)
        context.insert(stress)
        let clock = ContinuousClock()
        let saveStart = clock.now
        try context.save()
        print("M11 native 501 recordings including stress graph SwiftData save: \(saveStart.duration(to: clock.now))")
        let readContext = ModelContext(container)
        let fetchStart = clock.now
        let recordings = try readContext.fetch(FetchDescriptor<Recording>(sortBy: [SortDescriptor(\Recording.importedAt)]))
        print("M11 native 501 recordings metadata fetch: \(fetchStart.duration(to: clock.now))")
        #expect(recordings.count == 501)
        let reopened = try #require(recordings.first { $0.id == stress.id })
        #expect(reopened.transcript?.segments.count == 6000)
        #expect(reopened.chatSessions.first?.messages.count == 260)
        #expect(reopened.sources.count == 105)
        #expect(reopened.summaryHistory.count == 8)
    }
}
