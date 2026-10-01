import Foundation
import SwiftData

enum ProjectEditingError: LocalizedError {
    case emptyName, invalidOwner, busy
    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a project name."
        case .invalidOwner: "This source does not belong to the project."
        case .busy: "Cancel project imports first. Recording processing must finish before deleting recordings."
        }
    }
}

@MainActor
protocol ProjectEditing {
    func create(name: String, description: String?) throws -> Project
    func rename(_ project: Project, name: String, description: String?) throws
    func move(_ recording: Recording, to project: Project?) throws
    func delete(_ project: Project, deletingRecordings: Bool) throws
    func deleteSource(_ source: RecordingSource, from project: Project) throws
    func renameSource(_ source: RecordingSource, in project: Project, name: String) throws
}

@MainActor
struct SwiftDataProjectRepository: ProjectEditing {
    let context: ModelContext
    var storage = LibraryStorage()

    func create(name: String, description: String? = nil) throws -> Project {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectEditingError.emptyName }
        let project = Project(name: name, projectDescription: clean(description))
        context.insert(project)
        do { try context.save() }
        catch { context.delete(project); throw error }
        return project
    }

    func rename(_ project: Project, name: String, description: String?) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectEditingError.emptyName }
        let previous = (project.name, project.projectDescription, project.updatedAt)
        project.name = name
        project.projectDescription = clean(description)
        project.updatedAt = .now
        do { try context.save() }
        catch { (project.name, project.projectDescription, project.updatedAt) = previous; throw error }
    }

    func move(_ recording: Recording, to project: Project?) throws {
        guard recording.project?.id != project?.id else { return }
        let previous = recording.project
        let oldDate = previous?.updatedAt
        let newDate = project?.updatedAt
        recording.project = project
        previous?.updatedAt = .now
        project?.updatedAt = .now
        do { try context.save() }
        catch {
            recording.project = previous
            if let oldDate { previous?.updatedAt = oldDate }
            if let newDate { project?.updatedAt = newDate }
            throw error
        }
    }

    func renameSource(_ source: RecordingSource, in project: Project, name: String) throws {
        guard source.project?.id == project.id, source.recording == nil else { throw ProjectEditingError.invalidOwner }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectEditingError.emptyName }
        let previous = (source.displayName, project.updatedAt)
        source.displayName = name
        project.updatedAt = .now
        do { try context.save() }
        catch { (source.displayName, project.updatedAt) = previous; throw error }
    }

    func deleteSource(_ source: RecordingSource, from project: Project) throws {
        guard source.project?.id == project.id, source.recording == nil, !source.isPrimaryAudio else { throw ProjectEditingError.invalidOwner }
        guard source.status != .processing else { throw ProjectEditingError.busy }
        try stageAndCommit([storage.sourceDirectory(id: source.id)]) {
            project.updatedAt = .now
            context.delete(source)
        }
    }

    func delete(_ project: Project, deletingRecordings: Bool = false) throws {
        guard !project.sources.contains(where: { $0.status == .processing }) else { throw ProjectEditingError.busy }
        let recordings = project.recordings
        if deletingRecordings {
            guard !recordings.contains(where: { recording in
                recording.sources.contains { $0.status == .processing }
                    || recording.generationRecords.contains { $0.statusRaw == GenerationStatus.inProgress.rawValue }
            }) else { throw ProjectEditingError.busy }
        }
        var owned = Set(project.sources.map { storage.sourceDirectory(id: $0.id) })
        if deletingRecordings {
            for recording in recordings {
                if !recording.audioFileName.isEmpty { owned.insert(storage.recordingURL(fileName: recording.audioFileName)) }
                for source in recording.sources {
                    if source.isPrimaryAudio {
                        if !source.localFileReference.isEmpty { owned.insert(storage.sourceURL(source)) }
                    } else { owned.insert(storage.sourceDirectory(id: source.id)) }
                }
            }
        }
        try stageAndCommit(Array(owned)) {
            for recording in recordings {
                recording.project = nil
                if deletingRecordings { context.delete(recording) }
            }
            context.delete(project)
        }
    }

    // Stage only managed files; database failure restores them before returning.
    private func stageAndCommit(_ urls: [URL], mutation: () -> Void) throws {
        let files = FileManager.default
        let staging = storage.rootURL.appending(path: "ProjectRemoval-" + UUID().uuidString)
        var moved: [(URL, URL)] = []
        do {
            for url in urls where files.fileExists(atPath: url.path) {
                try files.createDirectory(at: staging, withIntermediateDirectories: true)
                let temporary = staging.appending(path: UUID().uuidString)
                try files.moveItem(at: url, to: temporary)
                moved.append((url, temporary))
            }
            mutation()
            do { try context.save() } catch { context.rollback(); throw error }
        } catch {
            for (original, temporary) in moved.reversed() { try files.moveItem(at: temporary, to: original) }
            try? files.removeItem(at: staging)
            throw error
        }
        if files.fileExists(atPath: staging.path) {
            do { try files.removeItem(at: staging) }
            catch { throw WorkspaceDeletionError.cleanupFailed(error) }
        }
    }

    private func clean(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
