import Foundation
import SwiftData
import Testing
@testable import AudioNotes

/// M14.1: persistence workflows and prompt/error state moved out of SwiftUI views.
@MainActor
struct PresentationBoundaryTests {
    private struct TechnicalError: Error, LocalizedError {
        var errorDescription: String? { "NSCocoaErrorDomain Code=134030 SQLite constraint" }
    }

    @MainActor private final class FakeWorkspaceRepository: WorkspaceEditing {
        var fails = false
        private(set) var renamed: [(UUID, String)] = []
        private(set) var deleted: [UUID] = []
        func rename(_ recording: Recording, to title: String) throws {
            if fails { throw TechnicalError() }
            renamed.append((recording.id, title))
        }
        func delete(_ recording: Recording) throws {
            if fails { throw TechnicalError() }
            deleted.append(recording.id)
        }
    }

    @MainActor private final class FakeProjectRepository: ProjectEditing {
        var error: Error?
        private(set) var moves: [(UUID, UUID?)] = []
        private(set) var renamedSources: [(UUID, String)] = []
        private(set) var deletedSources: [UUID] = []
        var created: Project?
        func create(name: String, description: String?) throws -> Project {
            if let error { throw error }
            let project = Project(name: name, projectDescription: description)
            created = project
            return project
        }
        func rename(_ project: Project, name: String, description: String?) throws { if let error { throw error } }
        func move(_ recording: Recording, to project: Project?) throws {
            if let error { throw error }
            moves.append((recording.id, project?.id))
        }
        func delete(_ project: Project, deletingRecordings: Bool) throws { if let error { throw error } }
        func deleteSource(_ source: RecordingSource, from project: Project) throws {
            if let error { throw error }
            deletedSources.append(source.id)
        }
        func renameSource(_ source: RecordingSource, in project: Project, name: String) throws {
            if let error { throw error }
            renamedSources.append((source.id, name))
        }
    }

    @MainActor private struct FailingSummaryRepository: SummaryStoring {
        func save(_ newSummary: Summary, for recording: Recording) throws { throw TechnicalError() }
        func makeCurrent(_ summary: Summary, for recording: Recording) throws { throw TechnicalError() }
        func delete(_ summary: Summary, for recording: Recording) throws { throw TechnicalError() }
    }

    private func recording(_ title: String = "Lecture") -> Recording {
        Recording(title: title, audioFileName: "", originalFileName: "", duration: 0)
    }

    // MARK: Library prompts

    @Test func renamePromptPrefillsTitleAndConfirmForwardsTrimmedName() {
        let model = LibraryViewModel()
        let recording = recording("Original")
        let repository = FakeWorkspaceRepository()
        model.requestRename(recording)
        #expect(model.prompt?.id == LibraryPrompt.renameRecording(recording).id)
        #expect(model.renameText == "Original")
        model.renameText = "  Renamed \n"
        model.confirmRename(recording, using: repository)
        #expect(model.prompt == nil)
        #expect(repository.renamed.map(\.1) == ["Renamed"])
        #expect(model.error == nil)
    }

    @Test func persistenceFailureBecomesUserFacingWorkspaceError() {
        let model = LibraryViewModel()
        let recording = recording()
        let repository = FakeWorkspaceRepository()
        repository.fails = true
        model.requestRename(recording)
        model.renameText = "New"
        model.confirmRename(recording, using: repository)
        #expect(model.prompt == nil)
        #expect(model.error?.kind == .workspace)
        #expect(model.error?.title == "Workspace could not be updated")
        #expect(model.error?.message == "The new name could not be saved. Try again.")
        #expect(model.error?.message.contains("NSCocoaErrorDomain") == false)
    }

    @Test func deleteConfirmationIsExplicitAndFailureKeepsSelection() {
        let model = LibraryViewModel()
        let recording = recording()
        model.selectRecording(recording.id)
        let repository = FakeWorkspaceRepository()
        model.requestDelete(recording)
        #expect(model.prompt?.id == LibraryPrompt.deleteRecording(recording).id)
        #expect(repository.deleted.isEmpty)
        repository.fails = true
        model.confirmDelete(recording, using: repository)
        #expect(model.prompt == nil)
        #expect(model.selection == recording.id)
        #expect(model.error?.message == "The recording could not be deleted. Nothing was removed.")
        repository.fails = false
        model.requestDelete(recording)
        model.confirmDelete(recording, using: repository)
        #expect(repository.deleted == [recording.id])
        #expect(model.selection == nil)
    }

    @Test func newErrorReplacesPreviousAndDismissalClearsIt() {
        let model = LibraryViewModel()
        let repository = FakeProjectRepository()
        repository.error = TechnicalError()
        model.move(recording(), to: nil, using: repository)
        let first = model.error
        model.saveProject(nil, name: "Project", description: nil, using: repository)
        #expect(model.error != first)
        #expect(model.error?.message == "The project could not be saved. Try again.")
        model.error = nil
        #expect(model.error == nil)
    }

    @Test func droppedRecordingsResolveAgainstLibraryAndSelectProject() {
        let model = LibraryViewModel()
        let project = Project(name: "Systems")
        let member = recording("Member")
        member.project = project
        let standalone = recording("Standalone")
        let repository = FakeProjectRepository()
        model.moveRecordings([member.id, standalone.id, UUID()], to: project, from: [member, standalone], using: repository)
        #expect(repository.moves.map(\.0) == [standalone.id])
        #expect(model.destination == .project(project.id))
        #expect(model.error == nil)
    }

    @Test func failedDropReportsErrorWithoutNavigating() {
        let model = LibraryViewModel()
        let repository = FakeProjectRepository()
        repository.error = TechnicalError()
        let standalone = recording()
        model.moveRecordings([standalone.id], to: Project(name: "Systems"), from: [standalone], using: repository)
        #expect(model.destination == .allRecordings)
        #expect(model.error?.message == "The recordings could not be moved. Try again.")
    }

    @Test func savingProjectSelectsCreatedProjectAndKeepsDomainMessages() throws {
        let model = LibraryViewModel()
        let repository = FakeProjectRepository()
        model.saveProject(nil, name: "Operating Systems", description: nil, using: repository)
        #expect(model.destination == .project(try #require(repository.created).id))
        repository.error = ProjectEditingError.emptyName
        model.saveProject(Project(name: "Existing"), name: " ", description: nil, using: repository)
        #expect(model.error?.message == ProjectEditingError.emptyName.localizedDescription)
    }

    @Test func revealWithoutManagedFilesReportsInsteadOfOpeningFinder() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let model = LibraryViewModel()
        #expect(model.urlsToReveal(for: recording(), storage: workspace.storage).isEmpty)
        #expect(model.error?.message == "This workspace has no available imported files to reveal.")
    }

    @Test func projectDeletionConfirmationDeletesProjectAndKeepsRecordings() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let project = Project(name: "Systems")
        let member = recording()
        context.insert(project)
        context.insert(member)
        member.project = project
        try context.save()
        let model = LibraryViewModel()
        model.selectProject(project.id)
        model.requestDeleteProject(project)
        #expect(model.prompt?.id == LibraryPrompt.deleteProject(project).id)
        await model.confirmDeleteProject(project, deletingRecordings: false, context: context)
        #expect(model.prompt == nil)
        #expect(!model.isDeletingProject)
        #expect(model.destination == .allRecordings)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 0)
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.id) == [member.id])
        #expect(model.error == nil)
    }

    @Test func importIntoDeletedProjectIsIgnored() async throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let project = Project(name: "Gone")
        context.insert(project)
        try context.save()
        context.delete(project)
        let model = LibraryViewModel()
        await model.importFiles([try workspace.makeAudio()], to: project, context: context)
        #expect(model.projectImports.items.isEmpty)
        #expect(model.error == nil)
    }

    // MARK: Project workspace

    @Test func workspaceSourceRenamePromptAndForwarding() {
        let model = ProjectWorkspaceViewModel()
        let project = Project(name: "Systems")
        let source = RecordingSource(type: .pdf, displayName: "slides.pdf", originalFilename: "slides.pdf", localFileReference: "original.pdf")
        let repository = FakeProjectRepository()
        model.requestRename(source)
        #expect(model.prompt?.id == ProjectWorkspaceViewModel.Prompt.renameSource(source).id)
        #expect(model.sourceName == "slides.pdf")
        model.sourceName = "Lecture slides"
        model.confirmRename(source, in: project, using: repository)
        #expect(model.prompt == nil)
        #expect(repository.renamedSources.map(\.1) == ["Lecture slides"])
    }

    @Test func workspaceErrorsKeepDomainTextAndHideTechnicalText() {
        let model = ProjectWorkspaceViewModel()
        let project = Project(name: "Systems")
        let source = RecordingSource(type: .pdf, displayName: "slides.pdf", originalFilename: "slides.pdf", localFileReference: "original.pdf")
        let repository = FakeProjectRepository()
        repository.error = ProjectEditingError.invalidOwner
        model.requestDelete(source)
        model.confirmDelete(source, from: project, using: repository)
        #expect(model.prompt == nil)
        #expect(model.errorMessage == ProjectEditingError.invalidOwner.localizedDescription)
        repository.error = TechnicalError()
        model.move(recording(), to: nil, using: repository)
        #expect(model.errorMessage == "The recording could not be moved. Try again.")
    }

    @Test func workspaceRecordingDeletionGoesThroughLibrary() {
        let library = LibraryViewModel()
        let model = ProjectWorkspaceViewModel()
        let recording = recording()
        library.selectRecording(recording.id)
        let repository = FakeWorkspaceRepository()
        model.requestDelete(recording)
        model.confirmDelete(recording, library: library, using: repository)
        #expect(model.prompt == nil)
        #expect(repository.deleted == [recording.id])
        #expect(library.selection == nil)
    }

    // MARK: Summary history

    @Test func summaryHistoryFailureIsReportedNotSwallowed() {
        let recording = recording()
        let model = SummaryViewModel(recording: recording, resolver: FixedLLMProviderResolver(provider: MockLLMProvider()))
        let version = Summary(text: "Earlier")
        #expect(!model.makeCurrent(version, using: FailingSummaryRepository()))
        #expect(model.historyError == "This summary version could not be made current. Try again.")
        model.historyError = nil
        #expect(!model.deleteVersion(version, using: FailingSummaryRepository()))
        #expect(model.historyError == "This summary version could not be deleted. Nothing was removed.")
    }

    @Test func summaryHistoryMakeCurrentAndDeletePersist() throws {
        let workspace = try TestWorkspace()
        defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let recording = recording()
        context.insert(recording)
        let repository = SwiftDataSummaryRepository(context: context)
        try repository.save(Summary(text: "First"), for: recording)
        try repository.save(Summary(text: "Second"), for: recording)
        try repository.save(Summary(text: "Third"), for: recording)
        let model = SummaryViewModel(recording: recording, resolver: FixedLLMProviderResolver(provider: MockLLMProvider()))
        let first = try #require(recording.summaryHistory.first { $0.text == "First" })
        #expect(model.makeCurrent(first, using: repository))
        #expect(recording.summary?.text == "First")
        let second = try #require(recording.summaryHistory.first { $0.text == "Second" })
        #expect(model.deleteVersion(second, using: repository))
        #expect(!recording.summaryHistory.contains { $0.text == "Second" })
        #expect(model.historyError == nil)
    }
}
