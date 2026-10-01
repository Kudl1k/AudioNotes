import Foundation
import SwiftData

/// Additive lightweight schema migration plus idempotent data backfill. Never moves legacy files.
@MainActor
struct SourceCompatibilityMigration {
    func backfill(context: ModelContext) throws {
        for recording in try context.fetch(FetchDescriptor<Recording>()) {
            ensurePrimaryAudio(for: recording, context: context)
            for source in recording.sources where source.status == .processing {
                source.status = .failed
                source.processingError = "Processing was interrupted when AudioNotes closed. Reprocess this source."
            }
        }
        for source in try context.fetch(FetchDescriptor<RecordingSource>()) where source.project != nil && source.status == .processing {
            source.status = .failed
            source.processingError = "Processing was interrupted when AudioNotes closed. Retry this source."
        }
        try context.save()
    }

    func ensurePrimaryAudio(for recording: Recording, context: ModelContext) {
        guard !recording.audioFileName.isEmpty, !recording.sources.contains(where: \.isPrimaryAudio) else { return }
        let source = RecordingSource(id: recording.id, type: .audio, displayName: recording.originalFileName,
            originalFilename: recording.originalFileName, localFileReference: recording.audioFileName,
            status: recording.transcript == nil ? .imported : .ready, importedAt: recording.importedAt)
        source.isPrimaryAudio = true
        source.metadata = .audio(duration: recording.duration)
        source.recording = recording
        context.insert(source)
    }
}

extension LibraryStorage {
    var sourcesURL: URL { rootURL.appending(path: "Sources", directoryHint: .isDirectory) }
    func sourceDirectory(id: UUID) -> URL { sourcesURL.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func sourceURL(id: UUID, filename: String) -> URL {
        sourceDirectory(id: id).appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
    }
    @MainActor func sourceURL(_ source: RecordingSource) -> URL {
        source.isPrimaryAudio ? recordingURL(fileName: source.localFileReference)
            : sourceURL(id: source.id, filename: source.localFileReference)
    }
}
