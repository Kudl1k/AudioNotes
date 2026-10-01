import Foundation
import SwiftData

enum RecordingSourceType: String, Codable, CaseIterable, Sendable {
    case audio, pdf, document, image
    var icon: String {
        switch self { case .audio: "waveform"; case .pdf, .document: "doc.text"; case .image: "photo" }
    }
}
enum SourceProcessingStatus: String, Codable, Sendable {
    case imported, processing, ready, partial, failed, unsupported
}
enum SourceTextOrigin: String, Codable, Sendable { case nativeText, ocr, transcript }

struct OCRRegion: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Float
}

enum SourceLocator: Codable, Hashable, Sendable {
    case audio(segmentIDs: [UUID], start: TimeInterval, end: TimeInterval)
    case pdf(pageIndex: Int)
    case document(section: String, start: Int, end: Int)
    case image(region: OCRRegion?)

    var locationLabel: String {
        switch self {
        case .audio(_, let start, _): TimestampFormatter.string(start)
        case .pdf(let index): "p. \(index + 1)"
        case .document(let section, _, _): section
        case .image: "Image"
        }
    }
}

enum SourceMetadata: Codable, Hashable, Sendable {
    case audio(duration: TimeInterval)
    case pdf(pageCount: Int, unreadablePages: [Int])
    case document(characterCount: Int)
    case image(width: Int, height: Int)
}

@Model
final class RecordingSource {
    @Attribute(.unique) var id: UUID
    var typeRaw: String
    var displayName: String
    var originalFilename: String
    var importedAt: Date
    var statusRaw: String
    /// Filename inside Sources/<source ID>; primary audio retains its M1–M8 filename.
    var localFileReference: String
    var isPrimaryAudio: Bool = false
    var contentHash: String?
    var metadataData: Data?
    var processingError: String?
    /// Exactly one owner is assigned by import/repository operations.
    var project: Project?
    var recording: Recording?
    @Relationship(deleteRule: .cascade, inverse: \SourceTextUnit.source)
    var textUnits: [SourceTextUnit] = []
    @Relationship(deleteRule: .cascade, inverse: \Transcript.source)
    var transcript: Transcript?

    var type: RecordingSourceType { RecordingSourceType(rawValue: typeRaw) ?? .document }
    var status: SourceProcessingStatus {
        get { SourceProcessingStatus(rawValue: statusRaw) ?? .unsupported }
        set { statusRaw = newValue.rawValue }
    }
    var metadata: SourceMetadata? {
        get { metadataData.flatMap { try? JSONDecoder().decode(SourceMetadata.self, from: $0) } }
        set { metadataData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    var authoritativeTranscript: Transcript? { isPrimaryAudio ? recording?.transcript : transcript }
    var isContextReady: Bool {
        type == .audio ? !(authoritativeTranscript?.segments.isEmpty ?? true) : status == .ready || status == .partial
    }

    init(id: UUID = UUID(), type: RecordingSourceType, displayName: String, originalFilename: String,
         localFileReference: String, status: SourceProcessingStatus = .imported, importedAt: Date = .now) {
        self.id = id
        typeRaw = type.rawValue
        self.displayName = displayName
        self.originalFilename = originalFilename
        self.localFileReference = localFileReference
        statusRaw = status.rawValue
        self.importedAt = importedAt
    }
}

/// Page/section/region text is persisted once. Search chunks are derived snapshots.
@Model
final class SourceTextUnit {
    @Attribute(.unique) var id: UUID
    var position: Int
    var text: String
    var originRaw: String
    var locatorData: Data
    var source: RecordingSource?
    var origin: SourceTextOrigin { SourceTextOrigin(rawValue: originRaw) ?? .nativeText }
    var locator: SourceLocator? { try? JSONDecoder().decode(SourceLocator.self, from: locatorData) }

    init(id: UUID = UUID(), position: Int, text: String, origin: SourceTextOrigin, locator: SourceLocator) throws {
        self.id = id
        self.position = position
        self.text = text
        originRaw = origin.rawValue
        locatorData = try JSONEncoder().encode(locator)
    }
}

struct SourceReference: Codable, Hashable, Identifiable, Sendable {
    var id: UUID { chunkID }
    let sourceID: UUID
    let chunkID: UUID
    let sourceName: String
    let sourceType: RecordingSourceType
    let locator: SourceLocator
    let excerpt: String
    var label: String { "\(sourceName) · \(locator.locationLabel)" }
}
