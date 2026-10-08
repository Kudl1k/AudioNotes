import CoreGraphics
import Foundation
import Vision

struct RecognizedSourceText: Sendable {
    let text: String
    let region: OCRRegion
}
protocol SourceOCR: Sendable {
    func recognize(_ image: CGImage) async throws -> [RecognizedSourceText]
}

struct VisionOCRService: SourceOCR {
    private let configureRequest: @Sendable (VNRecognizeTextRequest) throws -> Void

    init(configureRequest: @escaping @Sendable (VNRecognizeTextRequest) throws -> Void = { _ in }) {
        self.configureRequest = configureRequest
    }

    func recognize(_ image: CGImage) async throws -> [RecognizedSourceText] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try configureRequest(request)
        // Never ask Vision for an unsupported language on the installed OS.
        let supported = try request.supportedRecognitionLanguages()
        let preferred = ["cs-CZ", "en-US"].filter(supported.contains)
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        let cancellation = OCRRequestCancellation(request: request)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image).perform([request])
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return RecognizedSourceText(text: candidate.string, region: OCRRegion(x: box.minX, y: box.minY,
                width: box.width, height: box.height, confidence: candidate.confidence))
        }
    }
}

/// VNRequest supports cancellation from another thread. No mutable recognition results escape.
private final class OCRRequestCancellation: @unchecked Sendable {
    let request: VNRecognizeTextRequest
    init(request: VNRecognizeTextRequest) { self.request = request }
    func cancel() { request.cancel() }
}
