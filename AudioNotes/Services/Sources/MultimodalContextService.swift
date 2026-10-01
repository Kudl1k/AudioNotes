import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LLMInputCapabilities: Codable, Equatable, Sendable {
    var supportsTextInput = true
    var supportsImageInput = false
    var supportedImageFormats: [String] = []
    var maximumImagesPerRequest: Int? = nil
    var maximumImageBytes: Int? = nil
    var contextWindowTokens = 100_000
    var approximateTokensPerImage = 30_000

    static func known(model: String?, provider: LLMProviderID) -> Self {
        guard provider == .openAI, let model else { return Self() }
        let names = ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"]
        guard names.contains(where: { model == $0 || model.hasPrefix($0 + "-20") }) else { return Self() }
        // Conservative application ceilings, below the documented API payload/count ceilings.
        return Self(supportsImageInput: true, supportedImageFormats: ["image/jpeg", "image/png", "image/webp", "image/gif"],
            maximumImagesPerRequest: 2, maximumImageBytes: 5 * 1024 * 1024, contextWindowTokens: 100_000)
    }
}

struct LLMImageInput: Equatable, Sendable {
    let sourceID: UUID
    let chunkID: UUID
    let data: Data
    let mimeType: String
    var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
}

actor MultimodalContextService {
    let storage: LibraryStorage
    init(storage: LibraryStorage = LibraryStorage()) { self.storage = storage }
    struct Candidate: Sendable { let sourceID: UUID; let chunkID: UUID; let url: URL }

    func prepare(candidates: [Candidate], capabilities: LLMInputCapabilities, allowed: Bool) throws -> [LLMImageInput] {
        guard allowed, capabilities.supportsImageInput, capabilities.supportedImageFormats.contains("image/jpeg") else { return [] }
        var images: [LLMImageInput] = []
        for candidate in candidates.prefix(min(2, capabilities.maximumImagesPerRequest ?? 2)) {
            try Task.checkCancellation()
            guard let cg = NativeSourceProcessingService.downsample(url: candidate.url, maximumDimension: 1536) else { throw SourceImportError.invalidFile }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw SourceImportError.invalidFile }
            CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination), data.length <= min(capabilities.maximumImageBytes ?? 5 * 1024 * 1024, 5 * 1024 * 1024) else { throw SourceImportError.tooLarge }
            images.append(.init(sourceID: candidate.sourceID, chunkID: candidate.chunkID, data: data as Data, mimeType: "image/jpeg"))
        }
        return images
    }
}
