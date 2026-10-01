import Foundation
import SwiftData

@MainActor
protocol RecordingStoring {
    func save(_ audio: ImportedAudio) throws
}

@MainActor
protocol WorkspaceEditing {
    func rename(_ recording: Recording, to title: String) throws
    func delete(_ recording: Recording) throws
}

enum WorkspaceDeletionError: LocalizedError {
    case cleanupFailed(Error)

    var errorDescription: String? {
        switch self {
        case .cleanupFailed(let error):
            "The workspace was deleted, but its staged files could not be removed: \(error.localizedDescription)"
        }
    }
}

@MainActor
struct SwiftDataRecordingRepository: RecordingStoring, WorkspaceEditing {
    let context: ModelContext
    var storage = LibraryStorage()

    func rename(_ recording: Recording, to title: String) throws {
        let previous = recording.title
        let projectDate = recording.project?.updatedAt
        recording.title = title
        recording.project?.updatedAt = .now
        do { try context.save() }
        catch {
            recording.title = previous
            if let projectDate { recording.project?.updatedAt = projectDate }
            throw error
        }
    }

    func delete(_ recording: Recording) throws {
        let files = FileManager.default
        var ownedURLs = Set(recording.sources.filter { !$0.isPrimaryAudio }.map { storage.sourceDirectory(id: $0.id) })
        if !recording.audioFileName.isEmpty {
            ownedURLs.insert(storage.recordingURL(fileName: recording.audioFileName))
        }
        for source in recording.sources where source.isPrimaryAudio && !source.localFileReference.isEmpty {
            ownedURLs.insert(storage.sourceURL(source))
        }
        let staging = storage.rootURL.appending(path: "WorkspaceRemoval-" + UUID().uuidString)
        var moved: [(original: URL, staged: URL)] = []
        // Keep owned files recoverable until the metadata deletion has committed.
        do {
            if ownedURLs.contains(where: { files.fileExists(atPath: $0.path) }) {
                try files.createDirectory(at: staging, withIntermediateDirectories: true)
            }
            for original in ownedURLs where files.fileExists(atPath: original.path) {
                let staged = staging.appending(path: UUID().uuidString)
                try files.moveItem(at: original, to: staged)
                moved.append((original, staged))
            }
            recording.project?.updatedAt = .now
            context.delete(recording)
            do { try context.save() }
            catch { context.rollback(); throw error }
        } catch {
            for item in moved.reversed() {
                try files.moveItem(at: item.staged, to: item.original)
            }
            if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
            throw error
        }
        if files.fileExists(atPath: staging.path) {
            do { try files.removeItem(at: staging) }
            catch { throw WorkspaceDeletionError.cleanupFailed(error) }
        }
    }

    func save(_ audio: ImportedAudio) throws {
        let recording = Recording(id: audio.id, title: audio.title, audioFileName: audio.fileName,
                                  originalFileName: audio.originalFileName, duration: audio.duration)
        context.insert(recording)
        SourceCompatibilityMigration().ensurePrimaryAudio(for: recording, context: context)
        do {
            try context.save()
        } catch {
            context.delete(recording)
            throw error
        }
    }
}
