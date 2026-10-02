#if DEBUG && os(macOS)
import CoreGraphics
import CoreText
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Opt-in isolated scene. No credentials, provider calls, or production database writes.
struct PerformanceFixtureLibrary: View {
    @Environment(\.modelContext) private var context
    @State private var isReady = false
    @State private var failure: String?

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("--performance-operation-settings") {
                OperationSettingsFixtureView()
            } else if isReady {
                LibraryView(transcriptionResolver: FixedTranscriptionProviderResolver(provider: ProcessInfo.processInfo.arguments.contains("--performance-layout") ? OperationFixtureTranscriptionProvider() : MockTranscriptionProvider()),
                    llmResolver: FixedLLMProviderResolver(provider: ProcessInfo.processInfo.arguments.contains("--performance-chat-stress") ? ChatPresentationFixtureProvider() : MockLLMProvider()))
            } else if let failure { Text("Fixture setup failed: " + failure).padding() }
            else { ProgressView("Preparing development fixtures…") }
        }
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--performance-light") ? .light : nil)
        .task {
            guard !ProcessInfo.processInfo.arguments.contains("--performance-operation-settings") else { return }
            guard !isReady else { return }
            do {
                if ProcessInfo.processInfo.arguments.contains("--performance-project-chat") {
                    try ProjectChatFixtures.prepare(context: context)
                    if ProcessInfo.processInfo.arguments.contains("--performance-long-names") { try ProjectChatFixtures.prepareLongNames(context: context) }
                    if ProcessInfo.processInfo.arguments.contains("--performance-layout") { try OperationPresentationFixtures.prepare(context: context) }
                    if ProcessInfo.processInfo.arguments.contains("--performance-chat-stress") { try ChatPresentationFixtures.prepare(context: context) }
                    isReady = true
                    return
                }
                var assets: [PerformanceFixtureAssets.Asset] = []
                let storage = LibraryStorage()
                for size in PerformanceFixtures.Size.allCases {
                    let recording = try PerformanceFixtures.recording(size)
                    context.insert(recording)
                    for source in recording.sources {
                        assets.append(.init(url: storage.sourceURL(source), type: source.type,
                            pages: size.pages, thumbnailURL: storage.sourceDirectory(id: source.id).appending(path: "thumbnail.jpg")))
                    }
                    await Task.yield()
                }
                for index in 0..<500 {
                    context.insert(Recording(id: PerformanceFixtures.id("library-\(index)"), title: "Recording \(index)",
                        audioFileName: "", originalFileName: "", duration: 300,
                        importedAt: PerformanceFixtures.epoch.addingTimeInterval(-Double(index + 1))))
                }
                if ProcessInfo.processInfo.arguments.contains("--performance-projects") {
                    var projects: [Project] = []
                    for index in 0..<100 {
                        let project = Project(id: PerformanceFixtures.id("project-\(index)"), name: String(format: "Project %03d", index),
                            projectDescription: index == 0 ? "Synthetic metadata fixture: 100 recordings and 200 shared sources." : nil,
                            createdAt: PerformanceFixtures.epoch)
                        context.insert(project)
                        projects.append(project)
                    }
                    let recordings = try context.fetch(FetchDescriptor<Recording>(sortBy: [SortDescriptor(\Recording.title)]))
                    for (index, recording) in recordings.enumerated() {
                        recording.project = projects[index < 100 ? 0 : 1 + index % 99]
                    }
                    for index in 0..<200 {
                        let source = RecordingSource(id: PerformanceFixtures.id("project-source-\(index)"), type: .pdf,
                            displayName: "Slides \(index)", originalFilename: "slides.pdf", localFileReference: "original.pdf", status: .ready,
                            importedAt: PerformanceFixtures.epoch.addingTimeInterval(Double(index)))
                        source.metadata = .pdf(pageCount: 2, unreadablePages: [])
                        source.textUnits = [try SourceTextUnit(id: PerformanceFixtures.id("project-unit-\(index)"), position: 0,
                            text: "Synthetic project slide text", origin: .nativeText, locator: .pdf(pageIndex: 0))]
                        source.project = projects[0]
                        context.insert(source)
                        assets.append(.init(url: storage.sourceURL(source), type: .pdf, pages: 2,
                            thumbnailURL: storage.sourceDirectory(id: source.id).appending(path: "thumbnail.jpg")))
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--performance-chat-stress") { try ChatPresentationFixtures.prepare(context: context) }
                try context.save()
                try await Task.detached { try PerformanceFixtureAssets.write(assets) }.value
                isReady = true
            } catch { failure = error.localizedDescription }
        }
    }
}

enum PerformanceFixtureAssets {
    struct Asset: Sendable {
        let url: URL
        let type: RecordingSourceType
        let pages: Int
        let thumbnailURL: URL
    }
    static func write(_ assets: [Asset]) throws {
        var pdfs: [Int: Data] = [:]
        let image = try imageData(width: 4096, height: 3072, type: UTType.png)
        let thumbnail = try imageData(width: 220, height: 165, type: UTType.jpeg)
        for asset in assets {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: asset.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if asset.type == .pdf {
                if pdfs[asset.pages] == nil { pdfs[asset.pages] = try pdfData(pages: asset.pages) }
                try pdfs[asset.pages]?.write(to: asset.url, options: .atomic)
            } else { try image.write(to: asset.url, options: .atomic) }
            try thumbnail.write(to: asset.thumbnailURL, options: .atomic)
        }
    }
    private static func imageData(width: Int, height: Int, type: UTType) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(red: 0.9, green: 0.95, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.25, alpha: 1))
        context.fill(CGRect(x: width / 8, y: height / 3, width: width * 3 / 4, height: height / 5))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
    private static func pdfData(pages: Int) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for index in 0..<pages {
            context.beginPDFPage(nil)
            let text = NSAttributedString(string: "Lecture Slides · Page \(index + 1)\n\nDriver registration, reading, writing and cleanup.\nČeský text a časové značky.",
                attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 18, nil)])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: 54, dy: 54), transform: nil), nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
#endif
