import Foundation
import Observation

/// Prompts and edits for one project workspace. Long-running work (imports, chat,
/// recording processing) stays with the library-owned models and queue.
@MainActor
@Observable
final class ProjectWorkspaceViewModel {
    enum Prompt: Identifiable {
        case deleteRecording(Recording)
        case deleteSource(RecordingSource)
        case renameSource(RecordingSource)

        var id: String {
            switch self {
            case .deleteRecording(let recording): "delete-recording-" + recording.id.uuidString
            case .deleteSource(let source): "delete-source-" + source.id.uuidString
            case .renameSource(let source): "rename-source-" + source.id.uuidString
            }
        }
    }

    var prompt: Prompt?
    var sourceName = ""
    var errorMessage: String?

    func requestDelete(_ recording: Recording) { prompt = .deleteRecording(recording) }
    func requestDelete(_ source: RecordingSource) { prompt = .deleteSource(source) }

    func requestRename(_ source: RecordingSource) {
        sourceName = source.displayName
        prompt = .renameSource(source)
    }

    func confirmDelete(_ recording: Recording, library: LibraryViewModel, using repository: any WorkspaceEditing) {
        prompt = nil
        // The library reports failures and releases the recording's retained models.
        library.delete(recording, using: repository)
    }

    func confirmDelete(_ source: RecordingSource, from project: Project, using repository: any ProjectEditing) {
        prompt = nil
        do { try repository.deleteSource(source, from: project) }
        catch { report(error, fallback: "The source could not be deleted. Nothing was removed.") }
    }

    func confirmRename(_ source: RecordingSource, in project: Project, using repository: any ProjectEditing) {
        prompt = nil
        do { try repository.renameSource(source, in: project, name: sourceName) }
        catch { report(error, fallback: "The new name could not be saved. Try again.") }
    }

    func move(_ recording: Recording, to project: Project?, using repository: any ProjectEditing) {
        do { try repository.move(recording, to: project) }
        catch { report(error, fallback: "The recording could not be moved. Try again.") }
    }

    private func report(_ error: Error, fallback: String) {
        errorMessage = UserFacingError.message(for: error, fallback: fallback)
    }
}
