import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct ExtractedSourceUnit: Sendable {
    let position: Int
    let text: String
    let origin: SourceTextOrigin
    let locator: SourceLocator
}
struct SourceProcessingResult: Sendable {
    let units: [ExtractedSourceUnit]
    let metadata: SourceMetadata
    let warnings: [String]
}
struct SourceProcessingProgress: Sendable {
    let phase: String
    let completed: Int
    let total: Int
}
typealias SourceProcessingProgressHandler = @Sendable (SourceProcessingProgress) async -> Void

protocol SourceProcessing: Sendable {
    func process(url: URL, type: RecordingSourceType,
                 progress: @escaping @Sendable (SourceProcessingProgress) async -> Void) async throws -> SourceProcessingResult
}

/// Actor owns PDFKit/Vision objects; only value snapshots cross to the UI actor.
actor NativeSourceProcessingService: SourceProcessing {
    let ocr: any SourceOCR
    init(ocr: any SourceOCR = VisionOCRService()) { self.ocr = ocr }

    func process(url: URL, type: RecordingSourceType,
                 progress: @escaping @Sendable (SourceProcessingProgress) async -> Void = { _ in }) async throws -> SourceProcessingResult {
        try Task.checkCancellation()
        switch type {
        case .pdf: return try await processPDF(url, progress: progress)
        case .image: return try await processImage(url, progress: progress)
        case .document: return try processDocument(url)
        case .audio: throw SourceImportError.unsupported
        }
    }

    private func processPDF(_ url: URL, progress: @escaping @Sendable (SourceProcessingProgress) async -> Void) async throws -> SourceProcessingResult {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw SourceImportError.invalidFile }
        guard !document.isLocked else { throw SourceImportError.encryptedPDF }
        var units: [ExtractedSourceUnit] = []
        var unreadable: [Int] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { unreadable.append(index); continue }
            let native = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var text = native
            var origin = SourceTextOrigin.nativeText
            if native.filter({ $0.isLetter || $0.isNumber }).count < 3 {
                await progress(.init(phase: "Reading scanned pages", completed: index, total: document.pageCount))
                do {
                    let image = page.thumbnail(of: CGSize(width: 2200, height: 2200), for: .mediaBox)
                    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw SourceImportError.invalidFile }
                    text = try await ocr.recognize(cgImage).map(\.text).joined(separator: "\n")
                    origin = .ocr
                } catch is CancellationError { throw CancellationError() }
                catch { unreadable.append(index) }
            } else {
                await progress(.init(phase: "Extracting text", completed: index, total: document.pageCount))
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !unreadable.contains(index) { unreadable.append(index) }
            // Preserve empty pages too; they never become retrieval candidates.
            units.append(.init(position: index, text: text, origin: origin, locator: .pdf(pageIndex: index)))
            if index == 0 { try? writeThumbnail(page.thumbnail(of: CGSize(width: 220, height: 280), for: .mediaBox), beside: url) }
            await progress(.init(phase: "Extracting text", completed: index + 1, total: document.pageCount))
        }
        guard units.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw SourceImportError.noText }
        return .init(units: units, metadata: .pdf(pageCount: document.pageCount, unreadablePages: unreadable),
            warnings: unreadable.isEmpty ? [] : ["No readable text on \(unreadable.count) page(s): \(unreadable.map { String($0 + 1) }.joined(separator: ", "))."])
    }

    private func processImage(_ url: URL, progress: @escaping @Sendable (SourceProcessingProgress) async -> Void) async throws -> SourceProcessingResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = Self.downsample(url: url, maximumDimension: 2000) else { throw SourceImportError.invalidFile }
        if let thumb = Self.downsample(url: url, maximumDimension: 220) {
            try? writeThumbnail(NSImage(cgImage: thumb, size: .zero), beside: url)
        }
        await progress(.init(phase: "Extracting text locally", completed: 0, total: 1))
        let observations = try await ocr.recognize(image)
        let units = observations.enumerated().map { index, item in
            ExtractedSourceUnit(position: index, text: item.text, origin: .ocr, locator: .image(region: item.region))
        }
        await progress(.init(phase: "OCR complete", completed: 1, total: 1))
        // A valid text-free image is usable as an explicitly selected visual source.
        return .init(units: units, metadata: .image(width: width, height: height),
            warnings: units.isEmpty ? ["No text detected. Visual understanding requires image upload and a vision-capable model."] : [])
    }

    private func processDocument(_ url: URL) throws -> SourceProcessingResult {
        let data = try Data(contentsOf: url)
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { text = String(data: data, encoding: .utf16) }
        else { text = String(data: data, encoding: .utf8) }
        guard let text else { throw SourceImportError.invalidFile }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SourceImportError.noText }
        var units: [ExtractedSourceUnit] = []
        var section = "Text"
        var offset = 0
        var sectionStart = 0
        var lines: [String] = []
        func flush() {
            let body = lines.joined(separator: "\n")
            if !body.isEmpty {
                units.append(.init(position: units.count, text: body, origin: .nativeText,
                    locator: .document(section: section, start: sectionStart, end: offset)))
            }
            lines = []
        }
        for line in text.components(separatedBy: "\n") {
            try Task.checkCancellation()
            if line.hasPrefix("#") && line.contains(" ") {
                flush()
                section = String(line.drop(while: { $0 == "#" || $0 == " " })).prefix(120).description
                sectionStart = offset
            }
            lines.append(line)
            offset += line.count + 1
        }
        flush()
        return .init(units: units, metadata: .document(characterCount: text.count), warnings: [])
    }

    static func downsample(url: URL, maximumDimension: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }
    private func writeThumbnail(_ image: NSImage, beside url: URL) throws {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let destination = url.deletingLastPathComponent().appending(path: "thumbnail.jpg")
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(writer, cg, nil)
        guard CGImageDestinationFinalize(writer) else { throw SourceImportError.invalidFile }
    }
}
