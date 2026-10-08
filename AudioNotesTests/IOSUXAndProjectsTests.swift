import Foundation
import SwiftData
import Testing
@testable import AudioNotes

@MainActor
struct IOSUXAndProjectsTests {
    private func makeRecording(workspace: TestWorkspace, context: ModelContext) async throws -> Recording {
        let audio = try await AudioImportService(storage: workspace.storage).importFile(at: workspace.makeAudio())
        let recording = Recording(id: audio.id, title: audio.title, audioFileName: audio.fileName, originalFileName: audio.originalFileName, duration: audio.duration)
        context.insert(recording)
        try context.save()
        return recording
    }

    @Test func createProjectThroughLibraryTrimsNameAndSelectsIt() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let library = LibraryViewModel()
        library.saveProject(nil, name: " University \n", description: nil, using: SwiftDataProjectRepository(context: context, storage: workspace.storage))
        let project = try #require(context.fetch(FetchDescriptor<Project>()).first)
        #expect(project.name == "University")
        #expect(library.projectSelection == project.id)
        #expect(library.error == nil)
    }

    @Test func blankProjectRejectedWithoutInsertion() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let library = LibraryViewModel()
        library.saveProject(nil, name: " \n\t", description: nil, using: SwiftDataProjectRepository(context: context, storage: workspace.storage))
        #expect(library.error != nil)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 0)
    }

    @Test func renameProjectPreservesIdentityAndDescription() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let repository = SwiftDataProjectRepository(context: context, storage: workspace.storage)
        let project = try repository.create(name: "Work", description: "Notes")
        let id = project.id
        LibraryViewModel().saveProject(project, name: " Meetings ", description: project.projectDescription, using: repository)
        #expect(project.id == id)
        #expect(project.name == "Meetings")
        #expect(project.projectDescription == "Notes")
    }

    @Test func movingAndRemovingKeepsRecordingHistoryAndFiles() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let repository = SwiftDataProjectRepository(context: context, storage: workspace.storage)
        let project = try repository.create(name: "Work", description: nil)
        let recording = try await makeRecording(workspace: workspace, context: context)
        recording.summary = Summary(text: "Preserve")
        let audio = try Data(contentsOf: workspace.storage.recordingURL(fileName: recording.audioFileName))
        let library = LibraryViewModel()
        library.move(recording, to: project, using: repository)
        #expect(recording.project?.id == project.id)
        #expect(project.recordings.map(\.id) == [recording.id])
        library.move(recording, to: nil, using: repository)
        #expect(recording.project == nil)
        #expect(project.recordings.isEmpty)
        #expect(recording.summary?.text == "Preserve")
        #expect(try Data(contentsOf: workspace.storage.recordingURL(fileName: recording.audioFileName)) == audio)
    }

    @Test func deleteKeepingRecordingsNullifiesMembership() async throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let repository = SwiftDataProjectRepository(context: context, storage: workspace.storage)
        let project = try repository.create(name: "Work", description: nil)
        let recording = try await makeRecording(workspace: workspace, context: context)
        try repository.move(recording, to: project)
        let library = LibraryViewModel()
        library.requestDeleteProject(project)
        await library.confirmDeleteProject(project, deletingRecordings: false, context: context)
        #expect(library.prompt == nil)
        #expect(!library.isDeletingProject)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Recording>()) == 1)
        #expect(recording.project == nil)
    }

    @Test func destructiveRequestDoesNotDeleteUntilConfirmation() throws {
        let workspace = try TestWorkspace(); defer { workspace.cleanUp() }
        let context = ModelContext(try workspace.storage.makeContainer(inMemory: true))
        let project = try SwiftDataProjectRepository(context: context, storage: workspace.storage).create(name: "Work", description: nil)
        let library = LibraryViewModel()
        library.requestDeleteProject(project)
        #expect(library.prompt?.id == "delete-project-" + project.id.uuidString)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 1)
        library.prompt = nil
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 1)
    }

    @Test func transcriptionAvailabilityRequiresConnectedTranscriptionCredentials() {
        #expect(IOSProviderAvailability.transcription(openAIKey: false, geminiConnected: false).isEmpty)
        #expect(IOSProviderAvailability.transcription(openAIKey: true, geminiConnected: false) == [.openAI])
        #expect(IOSProviderAvailability.transcription(openAIKey: false, geminiConnected: true) == [.gemini])
        #expect(IOSProviderAvailability.transcription(openAIKey: true, geminiConnected: true) == [.openAI, .gemini])
        #expect(!IOSProviderAvailability.transcription(openAIKey: true, geminiConnected: true).contains(.localWhisper))
    }

    @Test func transcriptionDefaultsResolveWithoutExplicitOverrides() {
        let resolver = UXTranscriptionResolver()
        let model = RecordingViewModel(recording: Recording(title: "Review", audioFileName: "review.wav", originalFileName: "review.wav", duration: 60), resolver: resolver)
        #expect(!model.hasTranscriptionOverrides)
        _ = model.providerName
        #expect(resolver.lastProvider == nil && resolver.lastModel == nil && resolver.lastLanguage == nil)
    }

    @Test func recordingOverridesReachResolverAndProviderChangeClearsModel() {
        let resolver = UXTranscriptionResolver()
        let model = RecordingViewModel(recording: Recording(title: "Review", audioFileName: "review.wav", originalFileName: "review.wav", duration: 60), resolver: resolver)
        model.selectedProvider = .openAI
        model.selectedModel = "whisper-1"
        model.selectedLanguage = .czech
        _ = model.providerName
        #expect(model.hasTranscriptionOverrides)
        #expect(resolver.lastProvider == .openAI && resolver.lastModel == "whisper-1" && resolver.lastLanguage == .czech)
        model.selectedProvider = .gemini
        #expect(model.selectedModel == nil)
    }

    @Test func resetOverridesReturnsToLiveDefaults() {
        let resolver = UXTranscriptionResolver()
        let model = RecordingViewModel(recording: Recording(title: "Review", audioFileName: "review.wav", originalFileName: "review.wav", duration: 60), resolver: resolver)
        model.selectedProvider = .openAI; model.selectedModel = "whisper-1"; model.selectedLanguage = .english
        model.resetTranscriptionOverrides()
        #expect(!model.hasTranscriptionOverrides)
        _ = model.providerName
        #expect(resolver.lastProvider == nil && resolver.lastModel == nil && resolver.lastLanguage == nil)
    }

    @Test func accountConnectionDoesNotImplyPlanAuthorization() {
        let account = ChatGPTAccount(id: "synthetic", issuedClientID: "test", grantedScopes: [], planUsageEnabled: false, expiresAt: .distantFuture)
        #expect(ChatGPTAuthState.signedIn(account: account).account != nil)
        #expect(ChatGPTAuthState.signedIn(account: account).account?.planUsageEnabled == false)
        #expect(ChatGPTAuthState.signedOut.account == nil)
    }
}

@MainActor private final class UXTranscriptionResolver: TranscriptionProviderResolving {
    var lastProvider: TranscriptionProviderID?
    var lastModel: String?
    var lastLanguage: TranscriptionLanguage?
    func resolve() -> any TranscriptionProvider { MockTranscriptionProvider() }
    func resolve(provider: TranscriptionProviderID?, model: String?, language: TranscriptionLanguage?) -> any TranscriptionProvider {
        lastProvider = provider; lastModel = model; lastLanguage = language
        return MockTranscriptionProvider()
    }
}
