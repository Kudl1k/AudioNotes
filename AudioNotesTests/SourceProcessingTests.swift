import Foundation
import PDFKit
import Testing
@testable import AudioNotes

struct SourceProcessingTests {
    @Test func nativePDFPreservesEveryPageAndUnicodeWithoutOCR() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let pdf = workspace.root.appending(path: "slides.pdf")
        try writeSourceTestPDF(["English kernel", "Příliš žluťoučký kůň"], to: pdf)
        let ocr = FixtureOCR()
        let result = try await NativeSourceProcessingService(ocr: ocr).process(url: pdf, type: .pdf)
        #expect(result.units.count == 2)
        #expect(result.units[0].locator == .pdf(pageIndex: 0))
        #expect(result.units[1].locator.locationLabel == "p. 2")
        #expect(result.units[1].text.contains("žluťoučký"))
        #expect(result.units.allSatisfy { $0.origin == .nativeText })
        #expect(ocr.calls == 0)
    }
    @Test func emptyPageUsesOCRFallbackAndPartialFailureKeepsProvenance() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let pdf = workspace.root.appending(path: "mixed.pdf")
        try writeSourceTestPDF(["Native text", nil, "Last page"], to: pdf)
        let ocr = FixtureOCR(fails: true)
        let result = try await NativeSourceProcessingService(ocr: ocr).process(url: pdf, type: .pdf)
        #expect(ocr.calls == 1)
        #expect(result.units.count == 3)
        #expect(result.units[1].text.isEmpty)
        #expect(result.units[2].locator == .pdf(pageIndex: 2))
        #expect(result.metadata == .pdf(pageCount: 3, unreadablePages: [1]))
        #expect(!result.warnings.isEmpty)
    }
    @Test func scannedPDFUsesOCRAndKeepsPageIndex() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let pdf = workspace.root.appending(path: "scan.pdf")
        let document = PDFDocument()
        let image = try sourceTestImage(text: "Scanned text")
        let page = try #require(PDFPage(image: .init(cgImage: image, size: .zero)))
        document.insert(page, at: 0)
        #expect(document.write(to: pdf))
        let ocr = FixtureOCR()
        let result = try await NativeSourceProcessingService(ocr: ocr).process(url: pdf, type: .pdf)
        #expect(ocr.calls == 1)
        #expect(result.units.first?.origin == .ocr)
        #expect(result.units.first?.locator == .pdf(pageIndex: 0))
        #expect(result.units.first?.text == "Scanned český text")
    }
    @Test(arguments: ["jpeg", "png", "heic"])
    func imageFormatsDimensionsAndOCRRegions(format: String) async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "image." + format)
        let image = try sourceTestImage(text: "English český text")
        try writeSourceTestImage(image, to: file, type: "public." + format)
        let result = try await NativeSourceProcessingService(ocr: FixtureOCR()).process(url: file, type: .image)
        #expect(result.metadata == .image(width: 1600, height: 800))
        #expect(result.units.first?.origin == .ocr)
        #expect(result.units.first?.text.contains("český") == true)
        if case .image(let region) = result.units.first?.locator { #expect(region?.confidence == 0.8) }
        else { Issue.record("Missing image locator") }
        #expect(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appending(path: "thumbnail.jpg").path))
    }
    @Test func textFreeImageIsReadyForOptionalVisualContext() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "blank.png")
        try writeSourceTestImage(sourceTestImage(text: ""), to: file, type: "public.png")
        let result = try await NativeSourceProcessingService(ocr: FixtureOCR(text: "")).process(url: file, type: .image)
        #expect(result.units.isEmpty)
        #expect(!result.warnings.isEmpty)
    }
    @Test(arguments: ["English operating systems", "Příliš žluťoučký kůň"])
    func realVisionOCRPreservesEnglishAndCzech(text: String) async throws {
        let output = try await VisionOCRService().recognize(sourceTestImage(text: text)).map(\.text).joined(separator: " ")
        #expect(!output.isEmpty)
        #expect(output.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).contains(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)), "OCR result: \(output)")
        if text.contains("ů") { #expect(output.contains { "říšžťčýůň".contains($0) }, "OCR should preserve recognized Unicode") }
    }
    @Test func markdownAndUTF16DocumentsPreserveTextAndSections() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        for encoding in [String.Encoding.utf8, .utf16] {
            let file = workspace.root.appending(path: "assignment.md")
            try "# Úvod\nPříliš žluťoučký kůň\n## Requirements\nDriver homework".data(using: encoding)!.write(to: file)
            let result = try await NativeSourceProcessingService().process(url: file, type: .document)
            #expect(result.units.count == 2)
            #expect(result.units.first?.text.contains("žluťoučký") == true)
            #expect(result.units.last?.locator.locationLabel == "Requirements")
            #expect(result.units.allSatisfy { $0.origin == .nativeText })
        }
    }
    @Test func largePDFAndLargeTextRemainPageAndRangeAddressable() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "large.pdf")
        try writeSourceTestPDF((0..<150).map { "Page \($0) kernel" }, to: file)
        let result = try await NativeSourceProcessingService(ocr: FixtureOCR()).process(url: file, type: .pdf)
        #expect(result.units.count == 150)
        #expect(result.units.last?.locator == .pdf(pageIndex: 149))
        let text = workspace.root.appending(path: "large.txt")
        try String(repeating: "České poznámky\n", count: 50_000).write(to: text, atomically: true, encoding: .utf8)
        let document = try await NativeSourceProcessingService().process(url: text, type: .document)
        #expect(document.units.first?.text.count ?? 0 > 500_000)
    }
    @Test(arguments: [RecordingSourceType.pdf, .image, .document])
    func corruptedContentFailsWithoutCrashing(type: RecordingSourceType) async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "bad")
        try Data([0xFF, 0x00, 0xFE, 0xAA]).write(to: file)
        await #expect(throws: (any Error).self) { try await NativeSourceProcessingService().process(url: file, type: type) }
    }
    @Test func OCRFailureAndEmptyDocumentAreTypedFailures() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let file = workspace.root.appending(path: "photo.png")
        try writeSourceTestImage(sourceTestImage(text: "OCR"), to: file, type: "public.png")
        await #expect(throws: SourceImportError.invalidFile) { try await NativeSourceProcessingService(ocr: FixtureOCR(fails: true)).process(url: file, type: .image) }
        let text = workspace.root.appending(path: "empty.txt")
        try Data().write(to: text)
        await #expect(throws: SourceImportError.noText) { try await NativeSourceProcessingService().process(url: text, type: .document) }
    }
}
