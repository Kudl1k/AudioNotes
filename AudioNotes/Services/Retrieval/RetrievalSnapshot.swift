import Foundation
import SwiftData

/// Immutable, retrieval-only copies. Never captures chat, summaries, billing, or managed files.
struct RetrievalSnapshot: Sendable {
    struct Segment: Codable, Equatable, Sendable {
        let id: UUID
        let start: Double
        let end: Double
        let text: String
        let speaker: String?
        init(_ segment: TranscriptSegment) {
            id = segment.id; start = segment.startTime; end = segment.endTime
            text = segment.text; speaker = segment.speaker
        }
        init(id: UUID, start: Double, end: Double, text: String, speaker: String? = nil) {
            self.id = id; self.start = start; self.end = end; self.text = text; self.speaker = speaker
        }
    }
    struct Unit: Codable, Equatable, Sendable {
        let id: UUID
        let position: Int
        let text: String
        let locator: SourceLocator?
        let origin: SourceTextOrigin
    }
    struct Source: Codable, Equatable, Sendable {
        let id: UUID
        let projectID: UUID?
        let recordingID: UUID?
        let recordingTitle: String?
        let name: String
        let filename: String
        let type: RecordingSourceType
        let segments: [Segment]
        let units: [Unit]
    }
    let scope: RetrievalScope
    let sources: [Source]
    let coverage: RetrievalCoverage
    let recordings: [RetrievalRecordingMetadata]

    init(scope: RetrievalScope, sources: [Source], coverage: RetrievalCoverage, recordings: [RetrievalRecordingMetadata] = []) {
        self.scope = scope; self.sources = sources; self.coverage = coverage; self.recordings = recordings
    }

    // includedSourceIDs is for request-scoped citation revalidation only. Cached retrieval
    // continues to capture the complete scope so unrelated cached sources are preserved.
    @MainActor static func capture(scope: RetrievalScope, context: ModelContext, includedSourceIDs: Set<UUID>? = nil) throws -> Self {
        var recordings: [Recording]
        var shared: [RecordingSource] = []
        switch scope {
        case .recording(let id):
            var fetch = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
            fetch.fetchLimit = 1
            recordings = try context.fetch(fetch)
            guard !recordings.isEmpty else { throw RetrievalError.scopeMissing }
        case .project(let id):
            var fetch = FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })
            fetch.fetchLimit = 1
            guard try context.fetch(fetch).first != nil else { throw RetrievalError.scopeMissing }
            recordings = try context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.project?.id == id }))
            shared = try context.fetch(FetchDescriptor<RecordingSource>(predicate: #Predicate { $0.project?.id == id && $0.recording == nil }))
        }
        var sources: [Source] = []
        var coverage = RetrievalCoverage()
        var metadata: [RetrievalRecordingMetadata] = []
        for recording in recordings {
            try Task.checkCancellation()
            let projectID = recording.project?.id
            let primaryID = recording.sources.first(where: \.isPrimaryAudio)?.id ?? recording.id
            let includesPrimary = includedSourceIDs?.contains(primaryID) ?? true
            let segments = includesPrimary ? recording.transcript?.segments.map(Segment.init) ?? [] : []
            let hasTranscript = segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            metadata.append(.init(id: recording.id, projectID: projectID, title: recording.title, hasTranscript: hasTranscript))
            if hasTranscript {
                coverage.searchableRecordings += 1
                let primary = recording.sources.first(where: \.isPrimaryAudio)
                sources.append(.init(id: primary?.id ?? recording.id, projectID: projectID,
                    recordingID: recording.id, recordingTitle: recording.title,
                    name: primary?.displayName ?? recording.originalFileName, filename: recording.originalFileName,
                    type: .audio, segments: segments, units: []))
            } else { coverage.untranscribedRecordings += 1 }
            for source in recording.sources where !source.isPrimaryAudio && source.recording?.id == recording.id && source.project == nil && (includedSourceIDs?.contains(source.id) ?? true) {
                append(source, projectID: projectID, recording: recording, sources: &sources, coverage: &coverage)
            }
        }
        for source in shared where includedSourceIDs?.contains(source.id) ?? true { append(source, projectID: source.project?.id, recording: nil, sources: &sources, coverage: &coverage) }
        return .init(scope: scope, sources: sources, coverage: coverage,
            recordings: metadata.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    @MainActor private static func append(_ source: RecordingSource, projectID: UUID?, recording: Recording?,
                                         sources: inout [Source], coverage: inout RetrievalCoverage) {
        if source.status == .processing || source.status == .imported { coverage.processingSources += 1; return }
        if source.status == .failed || source.status == .unsupported { coverage.failedSources += 1; return }
        guard source.isContextReady else { return }
        let segments = source.transcript?.segments.map(Segment.init) ?? []
        let units = source.textUnits.map { Unit(id: $0.id, position: $0.position, text: $0.text, locator: $0.locator, origin: $0.origin) }
        // Text-free images remain valid for existing explicit visual input, but are not OCR search documents.
        guard segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ||
                units.contains(where: { $0.locator != nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        coverage.searchableSources += 1
        sources.append(.init(id: source.id, projectID: projectID, recordingID: recording?.id,
            recordingTitle: recording?.title, name: source.displayName, filename: source.originalFilename,
            type: source.type, segments: segments, units: units))
    }
}

enum RetrievalError: LocalizedError {
    case scopeMissing
    var errorDescription: String? { "This recording or project is no longer available." }
}

struct RetrievalDocumentBuilder: Sendable {
    func documents(source: RetrievalSnapshot.Source) throws -> [RetrievalDocument] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let revision = StableSourceID.make(String(decoding: try encoder.encode(source), as: UTF8.self))
        var result: [RetrievalDocument] = []
        func append(text: String, key: String, locator: SourceLocator, origin: SourceTextOrigin, unitIDs: [UUID]) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let id = StableSourceID.make("retrieval-v1-\(source.id)-\(key)")
            let type: RetrievalContentType
            switch source.type {
            case .audio: type = .transcript
            case .pdf: type = .pdfText
            case .image: type = .imageOCR
            case .document: type = ["md", "markdown"].contains(URL(fileURLWithPath: source.filename).pathExtension.lowercased()) ? .markdown : .plainText
            }
            let chunk = SourceChunk(id: id, sourceID: source.id, sourceName: source.name, sourceType: source.type,
                                    text: text, locator: locator, origin: origin)
            result.append(.init(id: id, projectID: source.projectID, recordingID: source.recordingID,
                recordingTitle: source.recordingTitle, contentType: type, chunk: chunk, unitIDs: unitIDs, contentRevision: revision))
        }
        if source.type == .audio {
            let ordered = source.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted {
                $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
            }
            var start = 0
            while start < ordered.count {
                try Task.checkCancellation()
                var end = start
                var characters = 0
                while end < ordered.count {
                    let next = ordered[end]
                    if end > start && (characters + next.text.count > 3200 || next.end - ordered[start].start > 90 || next.start - ordered[end - 1].end > 15) { break }
                    characters += next.text.count
                    end += 1
                }
                let group = Array(ordered[start..<end])
                let ids = group.map(\.id)
                let text = group.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }.joined(separator: "\n")
                // Oversized individual segments are bounded, retaining the complete trusted segment locator.
                for (offset, part) in try Self.parts(text).enumerated() {
                    append(text: part.text, key: ids.map(\.uuidString).joined(separator: "-") + "-\(offset)",
                        locator: .audio(segmentIDs: ids, start: group[0].start, end: group.map(\.end).max() ?? group[0].end),
                        origin: .transcript, unitIDs: ids)
                }
                start = end < ordered.count && end - start > 2 ? end - 1 : end
            }
        } else {
            for unit in source.units.sorted(by: { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }) {
                try Task.checkCancellation()
                guard let locator = unit.locator else { continue }
                for part in try Self.parts(unit.text) {
                    var location = locator
                    if case .document(let section, let base, _) = locator {
                        location = .document(section: section, start: base + part.offset, end: base + part.offset + part.text.count)
                    }
                    append(text: part.text, key: "\(unit.id)-\(part.offset)", locator: location, origin: unit.origin, unitIDs: [unit.id])
                }
            }
        }
        return result
    }

    /// Prefer paragraphs/newlines/word boundaries; never cross an extracted page/section/region.
    private static func parts(_ text: String) throws -> [(offset: Int, text: String)] {
        var result: [(Int, String)] = []
        var start = text.startIndex
        var offset = 0
        while start < text.endIndex {
            try Task.checkCancellation()
            let hardEnd = text.index(start, offsetBy: 3200, limitedBy: text.endIndex) ?? text.endIndex
            var end = hardEnd
            if hardEnd != text.endIndex {
                let lower = text.index(start, offsetBy: 1600, limitedBy: hardEnd) ?? start
                let tail = text[lower..<hardEnd]
                if let paragraph = tail.range(of: "\n\n", options: .backwards) { end = paragraph.upperBound }
                else if let newline = tail.lastIndex(of: "\n") { end = text.index(after: newline) }
                else if let space = tail.lastIndex(of: " ") { end = text.index(after: space) }
            }
            let part = String(text[start..<end])
            result.append((offset, part)); offset += part.count; start = end
        }
        return result
    }
}
