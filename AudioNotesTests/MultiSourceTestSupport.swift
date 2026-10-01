import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
func multiSourceFixture() throws -> Recording {
    let recording = Recording(title: "Operating Systems", audioFileName: "lecture.m4a", originalFileName: "Lecture", duration: 120)
    let transcript = Transcript()
    transcript.segments = [TranscriptSegment(position: 0, startTime: 60, endTime: 70, text: "The professor moved the deadline to October seventeen. Kernel module discussion.")]
    recording.transcript = transcript
    let primary = RecordingSource(id: recording.id, type: .audio, displayName: "Lecture", originalFilename: "lecture.m4a", localFileReference: "lecture.m4a", status: .ready)
    primary.isPrimaryAudio = true
    primary.recording = recording
    let definitions: [(RecordingSourceType, String, String, SourceLocator, SourceTextOrigin)] = [
        (.pdf, "Slides", "The slide states October ten. Kernel module initialization uses module_init and module_exit.", .pdf(pageIndex: 17), .nativeText),
        (.image, "Whiteboard", "Semaphore synchronization handshake", .image(region: nil), .ocr),
        (.document, "Assignment", "Příliš žluťoučký kůň. Homework requires a character device driver.", .document(section: "Requirements", start: 0, end: 90), .nativeText)
    ]
    recording.sources = [primary]
    for (type, name, text, locator, origin) in definitions {
        let source = RecordingSource(type: type, displayName: name, originalFilename: name, localFileReference: "original", status: .ready)
        source.textUnits = [try SourceTextUnit(position: 0, text: text, origin: origin, locator: locator)]
        source.recording = recording
        recording.sources.append(source)
    }
    return recording
}

func sourceTestImage(text: String, width: Int = 1600, height: Int = 800) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
    context.textPosition = CGPoint(x: 70, y: height / 2)
    CTLineDraw(CTLineCreateWithAttributedString(string), context)
    return try #require(context.makeImage())
}

func writeSourceTestImage(_ image: CGImage, to url: URL, type: String) throws {
    let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
    CGImageDestinationAddImage(writer, image, nil)
    #expect(CGImageDestinationFinalize(writer))
}

func writeSourceTestPDF(_ pages: [String?], to url: URL) throws {
    var rect = CGRect(x: 0, y: 0, width: 600, height: 800)
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &rect, nil))
    for text in pages {
        context.beginPDFPage(nil)
        if let text {
            let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: 40, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        context.endPDFPage()
    }
    context.closePDF()
}

final class FixtureOCR: SourceOCR, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    let text: String
    let fails: Bool
    init(text: String = "Scanned český text", fails: Bool = false) { self.text = text; self.fails = fails }
    func recognize(_ image: CGImage) async throws -> [RecognizedSourceText] {
        lock.withLock { count += 1 }
        if fails { throw SourceImportError.invalidFile }
        if text.isEmpty { return [] }
        return [.init(text: text, region: .init(x: 0.1, y: 0.2, width: 0.7, height: 0.1, confidence: 0.8))]
    }
}
