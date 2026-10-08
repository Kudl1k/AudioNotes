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
                    guard let cgImage = Self.renderPage(page, targetSize: CGSize(width: 2200, height: 2200), box: .mediaBox) else {
                        throw SourceImportError.invalidFile
                    }
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
            if index == 0, let thumbnail = Self.renderPage(page, targetSize: CGSize(width: 220, height: 280), box: .mediaBox) {
                try? writeThumbnail(thumbnail, beside: url)
            }
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
            try? writeThumbnail(thumb, beside: url)
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

    static func renderPage(_ page: PDFPage, targetSize: CGSize, box: PDFDisplayBox = .mediaBox) -> CGImage? {
        let bounds = page.bounds(for: box)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let isRotated = (page.rotation == 90 || page.rotation == 270)
        let effectiveWidth = isRotated ? bounds.height : bounds.width
        let effectiveHeight = isRotated ? bounds.width : bounds.height
        guard effectiveWidth > 0, effectiveHeight > 0 else { return nil }

        let scale = min(targetSize.width / effectiveWidth, targetSize.height / effectiveHeight)
        let pixelWidth = max(1, Int(round(effectiveWidth * scale)))
        let pixelHeight = max(1, Int(round(effectiveHeight * scale)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        let transform = page.transform(for: box)
        context.concatenate(transform)
        page.draw(with: box, to: context)
        context.restoreGState()

        return context.makeImage()
    }

    static func downsample(url: URL, maximumDimension: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }
    private func writeThumbnail(_ cg: CGImage, beside url: URL) throws {
        let destination = url.deletingLastPathComponent().appending(path: "thumbnail.jpg")
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(writer, cg, nil)
        guard CGImageDestinationFinalize(writer) else { throw SourceImportError.invalidFile }
    }
}
