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

@MainActor
@Observable
final class LibraryViewModel {
    var selection: UUID?
    var projectSelection: UUID?
    let projectImports: ProjectImportQueue
    let retrieval = RetrievalService()
    var importError: String?
    var workspaceError: String?
    private(set) var isImporting = false
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
            workspaceError = ProjectEditingError.busy.localizedDescription
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
            workspaceError = ProjectEditingError.busy.localizedDescription
            return
        }
        do {
            try SwiftDataProjectRepository(context: context, storage: projectImports.storage).delete(project, deletingRecordings: deletingRecordings)
        } catch let error as WorkspaceDeletionError { workspaceError = error.localizedDescription }
        catch { workspaceError = error.localizedDescription; return }
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
        catch { workspaceError = error.localizedDescription }
    }

    func revealURLs(for recording: Recording, storage: LibraryStorage = LibraryStorage()) -> [URL] {
        var urls = Set(recording.sources.filter { !$0.localFileReference.isEmpty }.map { storage.sourceURL($0) })
        if !recording.audioFileName.isEmpty {
            urls.insert(storage.recordingURL(fileName: recording.audioFileName))
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    func delete(_ recording: Recording, using repository: any WorkspaceEditing) {
        guard canDelete(recording) else {
            workspaceError = "Wait for this workspace’s processing to finish before deleting it."
            return
        }
        let id = recording.id
        do {
            try repository.delete(recording)
        } catch let error as WorkspaceDeletionError {
            workspaceError = error.localizedDescription
        } catch {
            workspaceError = error.localizedDescription
            return
        }
        if selection == id { selection = nil }
        transcriptionModels.removeValue(forKey: id)
        sourcesModels.removeValue(forKey: id)
        summaryModels.removeValue(forKey: id)
        chatModels.removeValue(forKey: id)
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

    func importURLs(_ urls: [URL], into repository: any RecordingStoring) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        var failures: [String] = []
        for url in urls {
            if Task.isCancelled { break }
            do {
                let audio = try await importer.importFile(at: url)
                do {
                    try Task.checkCancellation()
                    try repository.save(audio)
                    selection = audio.id
                } catch {
                    do { try await importer.discard(audio) }
                    catch { failures.append("Could not remove unused copy: \(error.localizedDescription)") }
                    throw error
                }
            } catch is CancellationError {
                break
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { importError = failures.joined(separator: "\n\n") }
    }
}
