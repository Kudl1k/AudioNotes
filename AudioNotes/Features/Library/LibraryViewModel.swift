import Foundation
import Observation
import SwiftData

struct LibraryActivity: Identifiable, Sendable {
    let id: String
    let recordingID: UUID
    let title: String
    init(recording: Recording, feature: String, title: String) {
        id = recording.id.uuidString + feature
        recordingID = recording.id
        self.title = title + " · " + recording.title
    }
}

/// Confirmations and text prompts presented by the library window.
enum LibraryPrompt: Identifiable {
    case renameRecording(Recording)
    case deleteRecording(Recording)
    case deleteProject(Project)

    var id: String {
        switch self {
        case .renameRecording(let recording): "rename-recording-" + recording.id.uuidString
        case .deleteRecording(let recording): "delete-recording-" + recording.id.uuidString
        case .deleteProject(let project): "delete-project-" + project.id.uuidString
        }
    }
}

/// Blocking errors presented by the library window.
struct LibraryError: Identifiable, Equatable {
    enum Kind { case importFailed, workspace }
    let id = UUID()
    let kind: Kind
    let message: String

    var title: String {
        switch kind {
        case .importFailed: "Import could not be completed"
        case .workspace: "Workspace could not be updated"
        }
    }
}

@MainActor
@Observable
final class LibraryViewModel {
    var selection: UUID?
    var projectSelection: UUID?
    let projectImports: ProjectImportQueue
    let retrieval = RetrievalService()
    var prompt: LibraryPrompt?
    var renameText = ""
    var error: LibraryError?
    private(set) var isImporting = false
    private(set) var isDeletingProject = false
    @ObservationIgnored private let importer: any AudioImporting
    @ObservationIgnored private let imageLoader = SourceImageLoader()
    private var sourcesModels: [UUID: SourcesViewModel] = [:]
    func sourcesModel(for recording: Recording) -> SourcesViewModel {
        if let model = sourcesModels[recording.id] { return model }
        let model = SourcesViewModel(recording: recording, imageLoader: imageLoader)
        sourcesModels[recording.id] = model
        return model
    }

    private var transcriptionModels: [UUID: RecordingViewModel] = [:]
    private var summaryModels: [UUID: SummaryViewModel] = [:]
    var projectChatTabs = Set<UUID>()
    var pendingProjectCitation: ProjectCitation?
    private var projectChatModels: [UUID: ProjectChatViewModel] = [:]
    func projectChatModel(for project: Project, resolver: any LLMProviderResolving) -> ProjectChatViewModel {
        if let model = projectChatModels[project.id] { return model }
        let model = ProjectChatViewModel(project: project, resolver: resolver, retrieval: retrieval)
        projectChatModels[project.id] = model
        return model
    }

    private var chatModels: [UUID: ChatViewModel] = [:]

    func summaryModel(for recording: Recording, resolver: any LLMProviderResolving) -> SummaryViewModel {
        if let model = summaryModels[recording.id] { return model }
        let model = SummaryViewModel(recording: recording, resolver: resolver)
        summaryModels[recording.id] = model
        return model
    }

    func chatModel(for recording: Recording, resolver: any LLMProviderResolving) -> ChatViewModel {
        if let model = chatModels[recording.id] { return model }
        let model = ChatViewModel(recording: recording, resolver: resolver)
        chatModels[recording.id] = model
        return model
    }

    var activeOperations: [LibraryActivity] {
        let transcription = transcriptionModels.values.filter { $0.state.isProcessing }.map { LibraryActivity(recording: $0.recording, feature: "transcription", title: "Transcribing") }
        let summaries = summaryModels.values.filter { $0.state.isGenerating }.map { LibraryActivity(recording: $0.recording, feature: "summary", title: "Generating summary") }
        let chats = chatModels.values.filter { $0.isGenerating }.map { LibraryActivity(recording: $0.recording, feature: "chat", title: "Chat") }
        let sources = sourcesModels.values.filter { $0.isImporting || !$0.startedAt.isEmpty }.map { LibraryActivity(recording: $0.recording, feature: "sources", title: "Processing sources") }
        return (transcription + summaries + chats + sources).sorted { $0.id < $1.id }
    }

    init(importer: any AudioImporting = AudioImportService()) {
        self.importer = importer
        projectImports = ProjectImportQueue(imageLoader: imageLoader)
    }

    var destination: LibraryDestination {
        if let selection { return .recording(selection) }
        if let projectSelection { return .project(projectSelection) }
        return .allRecordings
    }

    func navigate(to destination: LibraryDestination) {
        switch destination {
        case .allRecordings: selection = nil; projectSelection = nil
        case .recording(let id): selectRecording(id)
        case .project(let id): selectProject(id)
        }
    }

    func selectProject(_ id: UUID) {
        selection = nil
        projectSelection = id
    }
    func selectRecording(_ id: UUID) {
        pendingProjectCitation = nil
        projectSelection = nil
        selection = id
    }

    func deleteProject(_ project: Project, deletingRecordings: Bool, context: ModelContext) async {
        if deletingRecordings && project.recordings.contains(where: { !canDelete($0) }) {
            showWorkspaceError(ProjectEditingError.busy.localizedDescription)
            return
        }
        let id = project.id
        let recordingIDs = deletingRecordings ? project.recordings.map(\.id) : []
        await projectChatModels[id]?.cancelAndWait()
        await retrieval.beginDeletion(.project(id))
        for recordingID in recordingIDs { await retrieval.beginDeletion(.recording(recordingID)) }
        defer {
            retrieval.endDeletion(.project(id))
            for recordingID in recordingIDs { retrieval.endDeletion(.recording(recordingID)) }
        }
        await projectImports.cancelAndWait(for: id)
        defer { projectImports.endDeletion(for: id) }
        if deletingRecordings && project.recordings.contains(where: { !canDelete($0) }) {
            showWorkspaceError(ProjectEditingError.busy.localizedDescription)
            return
        }
        do {
            try SwiftDataProjectRepository(context: context, storage: projectImports.storage).delete(project, deletingRecordings: deletingRecordings)
        } catch let error as WorkspaceDeletionError { showWorkspaceError(error.localizedDescription) }
        catch { showWorkspaceError(error, fallback: "The project could not be deleted. Nothing was removed."); return }
        if projectSelection == id { projectSelection = nil }
        for recordingID in recordingIDs {
            if selection == recordingID { selection = nil }
            transcriptionModels.removeValue(forKey: recordingID)
            sourcesModels.removeValue(forKey: recordingID)
            summaryModels.removeValue(forKey: recordingID)
            chatModels.removeValue(forKey: recordingID)
        }
        projectChatModels.removeValue(forKey: id)
        projectChatTabs.remove(id)
        projectImports.clearFinished(for: id)
    }

    func canDelete(_ recording: Recording) -> Bool {
        activeTranscriptionModel(for: recording) == nil
            && sourcesModels[recording.id]?.isImporting != true
            && !recording.sources.contains { sourcesModels[recording.id]?.isProcessing($0) == true || $0.status == .processing }
            && !recording.generationRecords.contains { $0.statusRaw == GenerationStatus.inProgress.rawValue }
    }

    func rename(_ recording: Recording, to title: String, using repository: any WorkspaceEditing) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do { try repository.rename(recording, to: title) }
        catch { showWorkspaceError(error, fallback: "The new name could not be saved. Try again.") }
    }

    func revealURLs(for recording: Recording, storage: LibraryStorage = LibraryStorage()) -> [URL] {
        var urls = Set(recording.sources.filter { !$0.localFileReference.isEmpty }.map { storage.sourceURL($0) })
        if !recording.audioFileName.isEmpty {
            urls.insert(storage.recordingURL(fileName: recording.audioFileName))
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    @discardableResult
    func delete(_ recording: Recording, using repository: any WorkspaceEditing) -> Bool {
        guard canDelete(recording) else {
            showWorkspaceError("Wait for this workspace’s processing to finish before deleting it.")
            return false
        }
        let id = recording.id
        do {
            try repository.delete(recording)
        } catch let error as WorkspaceDeletionError {
            showWorkspaceError(error.localizedDescription)
        } catch {
            showWorkspaceError(error, fallback: "The recording could not be deleted. Nothing was removed.")
            return false
        }
        if selection == id { selection = nil }
        transcriptionModels.removeValue(forKey: id)
        sourcesModels.removeValue(forKey: id)
        summaryModels.removeValue(forKey: id)
        chatModels.removeValue(forKey: id)
        return true
    }

    func transcriptionModel(for recording: Recording, resolver: any TranscriptionProviderResolving,
                            storage: LibraryStorage = LibraryStorage()) -> RecordingViewModel {
        if let model = transcriptionModels[recording.id] { return model }
        let model = RecordingViewModel(recording: recording, resolver: resolver, storage: storage)
        transcriptionModels[recording.id] = model
        return model
    }

    func activeTranscriptionModel(for recording: Recording) -> RecordingViewModel? {
        guard let model = transcriptionModels[recording.id], model.state.isProcessing else { return nil }
        return model
    }

    @discardableResult
    func importURLs(_ urls: [URL], into repository: any RecordingStoring,
                    failureMessage: ((Error) -> String)? = nil,
                    progress: ((Int) -> Void)? = nil) async -> AudioImportBatchResult {
        guard !isImporting else { return AudioImportBatchResult(importedCount: 0, failures: [], cancelled: true) }
        isImporting = true
        defer { isImporting = false }
        var failures: [String] = []
        var importedCount = 0
        for (index, url) in urls.enumerated() {
            if Task.isCancelled { break }
            progress?(index + 1)
            do {
                let audio = try await importer.importFile(at: url)
                do {
                    try Task.checkCancellation()
                    try repository.save(audio)
                    selection = audio.id
                    importedCount += 1
                } catch {
                    do { try await importer.discard(audio) }
                    catch { failures.append("Could not remove unused copy: \(error.localizedDescription)") }
                    throw error
                }
            } catch is CancellationError {
                break
            } catch {
                failures.append("\(url.lastPathComponent): \(failureMessage?(error) ?? error.localizedDescription)")
            }
        }
        if !failures.isEmpty { error = LibraryError(kind: .importFailed, message: failures.joined(separator: "\n\n")) }
        return AudioImportBatchResult(importedCount: importedCount, failures: failures, cancelled: Task.isCancelled)
    }

    /// Imports into a project's queue, or into the library when no project is targeted.
    func importFiles(_ urls: [URL], to project: Project?, context: ModelContext) async {
        if let project {
            guard !project.isDeleted else { return }
            projectImports.enqueue(urls, to: project, context: context)
        } else {
            await importURLs(urls, into: SwiftDataRecordingRepository(context: context))
        }
    }

    // MARK: Prompts

    func requestRename(_ recording: Recording) {
        renameText = recording.title
        prompt = .renameRecording(recording)
    }

    func requestDelete(_ recording: Recording) { prompt = .deleteRecording(recording) }

    func requestDeleteProject(_ project: Project) {
        guard !isDeletingProject else { return }
        prompt = .deleteProject(project)
    }

    func confirmRename(_ recording: Recording, using repository: any WorkspaceEditing) {
        prompt = nil
        rename(recording, to: renameText, using: repository)
    }

    func confirmDelete(_ recording: Recording, using repository: any WorkspaceEditing) {
        prompt = nil
        delete(recording, using: repository)
    }

    func confirmDeleteProject(_ project: Project, deletingRecordings: Bool, context: ModelContext) async {
        prompt = nil
        guard !isDeletingProject else { return }
        isDeletingProject = true
        defer { isDeletingProject = false }
        await deleteProject(project, deletingRecordings: deletingRecordings, context: context)
    }

    // MARK: Project membership and editing

    func move(_ recording: Recording, to project: Project?, using repository: any ProjectEditing) {
        do { try repository.move(recording, to: project) }
        catch { showWorkspaceError(error, fallback: "The recording could not be moved. Try again.") }
    }

    /// Moves dropped recordings into a project, resolving IDs against the current library.
    func moveRecordings(_ ids: [UUID], to project: Project, from recordings: [Recording], using repository: any ProjectEditing) {
        for id in ids {
            guard let recording = recordings.first(where: { $0.id == id }), recording.project?.id != project.id else { continue }
            do { try repository.move(recording, to: project) }
            catch { showWorkspaceError(error, fallback: "The recordings could not be moved. Try again."); return }
        }
        selectProject(project.id)
    }

    /// Creates a project when `editing` is nil, otherwise renames it.
    func saveProject(_ editing: Project?, name: String, description: String?, using repository: any ProjectEditing) {
        do {
            if let editing { try repository.rename(editing, name: name, description: description) }
            else { selectProject(try repository.create(name: name, description: description).id) }
        } catch { showWorkspaceError(error, fallback: "The project could not be saved. Try again.") }
    }

    /// Managed files to reveal; reports an error instead of returning an empty selection.
    func urlsToReveal(for recording: Recording, storage: LibraryStorage = LibraryStorage()) -> [URL] {
        let urls = revealURLs(for: recording, storage: storage)
        if urls.isEmpty { showWorkspaceError("This workspace has no available imported files to reveal.") }
        return urls
    }

    private func showWorkspaceError(_ message: String) {
        error = LibraryError(kind: .workspace, message: message)
    }

    private func showWorkspaceError(_ error: Error, fallback: String) {
        showWorkspaceError(UserFacingError.message(for: error, fallback: fallback))
    }
}
