#if DEBUG && os(macOS)
import Foundation

/// Deterministic, offline fixtures. Never inserted into the user's library automatically.
@MainActor
enum PerformanceFixtures {
    enum Size: String, CaseIterable {
        case small, medium, large, stress
        var duration: TimeInterval {
            switch self { case .small: 300; case .medium: 3600; case .large: 10800; case .stress: 21600 }
        }
        var segments: Int {
            switch self { case .small: 50; case .medium: 800; case .large: 2400; case .stress: 6000 }
        }
        var messages: Int {
            switch self { case .small: 3; case .medium: 30; case .large: 120; case .stress: 260 }
        }
        var pages: Int {
            switch self { case .small: 0; case .medium: 30; case .large, .stress: 100 }
        }
        var images: Int {
            switch self { case .small, .medium: 0; case .large: 4; case .stress: 104 }
        }
    }
    static func id(_ value: String) -> UUID { StableSourceID.make("m11-fixture-" + value) }
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static let paragraph = "The driver lifecycle includes registration, reading, writing, and cleanup. Disk errors require recovery. Český přepis zachovává diakritiku a časové značky. "
    static let markdown = "## Driver lifecycle\n\n" + String(repeating: paragraph + "\n\n", count: 16) + "\n1. Register the device.\n2. Release resources.\n\n```swift\nlet recording = source\n```\n"

    static func recording(_ size: Size) throws -> Recording {
        let name = size.rawValue
        let recording = Recording(id: id(name), title: "\(name.capitalized) Performance Fixture", audioFileName: "",
            originalFileName: "fixture.wav", duration: size.duration, importedAt: epoch)
        let transcript = Transcript(id: id(name + "-transcript"), languageCode: "cs", createdAt: epoch)
        transcript.segments = (0..<size.segments).reversed().map { index in
            let start = Double(index) * size.duration / Double(size.segments)
            return TranscriptSegment(id: id("\(name)-segment-\(index)"), position: index,
                startTime: start, endTime: start + size.duration / Double(size.segments),
                text: "Segment \(index). " + paragraph, speaker: index.isMultiple(of: 5) ? "Speaker A" : "Speaker B")
        }
        recording.transcript = transcript
        let session = ChatSession(id: id(name + "-chat"), createdAt: epoch, updatedAt: epoch)
        session.messages = (0..<size.messages).map { index in
            ChatMessage(id: id("\(name)-message-\(index)"), role: index.isMultiple(of: 2) ? .user : .assistant,
                text: index.isMultiple(of: 2) ? "Explain lifecycle \(index)." : markdown,
                createdAt: epoch.addingTimeInterval(Double(index)))
        }
        recording.chatSessions = [session]
        recording.summary = Summary(overview: markdown, preset: .lecture)
        recording.summaryHistory = (0..<(size == .large || size == .stress ? 8 : 0)).map { _ in Summary(overview: markdown, preset: .lecture) }
        if size.pages > 0 {
            let pdf = RecordingSource(id: id(name + "-pdf"), type: .pdf, displayName: "Lecture Slides", originalFilename: "slides.pdf", localFileReference: "slides.pdf", status: .ready, importedAt: epoch)
            pdf.metadata = .pdf(pageCount: size.pages, unreadablePages: [])
            pdf.textUnits = try (0..<size.pages).map { index in
                try SourceTextUnit(id: id("\(name)-page-\(index)"), position: index, text: String(repeating: paragraph, count: 8), origin: .nativeText, locator: .pdf(pageIndex: index))
            }
            recording.sources.append(pdf)
        }
        for index in 0..<size.images {
            let image = RecordingSource(id: id("\(name)-image-\(index)"), type: .image, displayName: "Whiteboard \(index)", originalFilename: "board.png", localFileReference: "board.png", status: .ready, importedAt: epoch)
            image.metadata = .image(width: 4096, height: 3072)
            image.textUnits = [try SourceTextUnit(id: id("\(name)-ocr-\(index)"), position: 0, text: paragraph, origin: .ocr, locator: .image(region: nil))]
            recording.sources.append(image)
        }
        return recording
    }
}
#endif
