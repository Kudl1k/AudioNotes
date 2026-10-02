import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let transcriptionResolver: any TranscriptionProviderResolving
    let llmResolver: any LLMProviderResolving
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.importedAt, order: .reverse) private var recordings: [Recording]
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var showsProjectEditor = false
    @State private var editingProject: Project?
    @State private var model = LibraryViewModel()
    @State private var isDropTargeted = false
    @State private var showsUsage = false
    @State private var showsActivity = false
    @SceneStorage("library.selection") private var restoredSelection = ""
    @AppStorage("libraryShowsCost") private var showsCost = false
    @Query private var generations: [GenerationRecord]
    @State private var costs = UsageDashboardSnapshot()

    init(
        transcriptionResolver: any TranscriptionProviderResolving,
        llmResolver: any LLMProviderResolving = FixedLLMProviderResolver(provider: MockLLMProvider())
    ) {
        self.transcriptionResolver = transcriptionResolver
        self.llmResolver = llmResolver
    }

    init(resolver: any TranscriptionProviderResolving) {
        self.init(transcriptionResolver: resolver, llmResolver: FixedLLMProviderResolver(provider: MockLLMProvider()))
    }

    private var selectedRecording: Recording? { recordings.first { $0.id == model.selection } }

    private var selectedProject: Project? { projects.first { $0.id == model.projectSelection } }
    private var activeImportProject: Project? { selectedProject ?? selectedRecording?.project }
    private var sidebarSelection: Binding<LibraryDestination?> {
        Binding(get: { model.destination }, set: { model.navigate(to: $0 ?? .allRecordings) })
    }

    private var navigation: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let selectedProject {
                ProjectWorkspaceView(project: selectedProject, projects: projects, queue: model.projectImports, library: model, llmResolver: llmResolver,
                    openRecording: { model.selectRecording($0) },
                    moveRecordingIDs: { move($0, to: $1) }, importFiles: showImporter)
                    .id(selectedProject.id)
            } else if let selectedRecording {
                RecordingDetailView(
                    recording: selectedRecording,
                    transcriptionResolver: transcriptionResolver,
                    llmResolver: llmResolver,
                    transcriptionModel: model.transcriptionModel(for: selectedRecording, resolver: transcriptionResolver),
                    sourcesModel: model.sourcesModel(for: selectedRecording),
                    summaryModel: model.summaryModel(for: selectedRecording, resolver: llmResolver),
                    chatModel: model.chatModel(for: selectedRecording, resolver: llmResolver),
                    projectCitation: model.pendingProjectCitation
                )
                .id(selectedRecording.id)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let project = selectedRecording.project {
                        HStack {
                            Button(project.name, systemImage: "folder") { model.pendingProjectCitation = nil; model.selectProject(project.id) }.buttonStyle(.link)
                            Image(systemName: "chevron.right").font(.caption)
                            Text(selectedRecording.title).lineLimit(1)
                            Spacer()
                            Menu("Organize") {
                                RecordingProjectMenu(recording: selectedRecording, projects: projects) { move(selectedRecording, to: $0) }
                            }
                        }.font(.caption).padding(.horizontal, 24).padding(.vertical, 8)
                    }
                }
            } else {
                AllRecordingsView(recordings: recordings, projects: projects, library: model, showsCost: showsCost, costs: costs,
                    open: { model.selectRecording($0.id) }, move: { move($0, to: $1) },
                    rename: { model.requestRename($0) },
                    delete: { model.requestDelete($0) }, importAudio: showImporter)
            }
        }
    }

    var body: some View {
        navigation
            .modifier(ProjectLibraryDialogs(model: model, showsEditor: $showsProjectEditor, editing: $editingProject))
            .onAppear {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--performance-fixtures"), model.selection == nil {
                    let args = ProcessInfo.processInfo.arguments
                    let size = args.firstIndex(of: "--performance-recording").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "large"
                    if args.contains("--performance-project-chat") {
                        model.projectChatTabs.insert(ProjectChatFixtures.projectID)
                        model.selectProject(ProjectChatFixtures.projectID)
                    } else if args.contains("--performance-projects") { model.selectProject(PerformanceFixtures.id("project-0")) }
                    else { model.selection = PerformanceFixtures.id(size) }
                }
#endif
                if model.destination == .allRecordings {
                    let destination = LibraryDestination(persistedValue: restoredSelection)
                        .available(recordingIDs: Set(recordings.map(\.id)), projectIDs: Set(projects.map(\.id)))
                    model.navigate(to: destination)
                }
            }
            .onChange(of: model.destination) { _, destination in restoredSelection = destination.persistedValue }
            .sheet(isPresented: $showsUsage) { UsageCostView() }
            .alert(promptTitle, isPresented: Binding(get: { model.prompt != nil }, set: { if !$0 { model.prompt = nil } }),
                   presenting: model.prompt) { prompt in
                promptActions(prompt)
            } message: { prompt in
                promptMessage(prompt)
            }
            .alert(model.error?.title ?? "", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } }),
                   presenting: model.error) { _ in
                Button("OK", role: .cancel) { model.error = nil }
            } message: { error in
                Text(error.message)
            }
            .task(id: generations.map { "\($0.id)-\($0.requestUsageData?.hashValue ?? 0)-\($0.statusRaw)" }.joined()) {
                costs = UsageRepository().snapshot(records: generations)
            }
            .toolbar {
                ToolbarItem {
                    if !model.activeOperations.isEmpty || model.projectImports.items.contains(where: \.isActive) {
                        Button("Activity: \(model.activeOperations.count + model.projectImports.items.filter(\.isActive).count)", systemImage: "clock") { showsActivity.toggle() }
                            .popover(isPresented: $showsActivity) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Activity").font(.headline)
                                    ForEach(model.activeOperations) { activity in
                                        Button(activity.title) { model.selectRecording(activity.recordingID); showsActivity = false }
                                            .buttonStyle(.link)
                                    }
                                    ForEach(projects.filter { model.projectImports.hasJobs(for: $0.id) }) { project in
                                        Button("Importing · " + project.name) { model.selectProject(project.id); showsActivity = false }.buttonStyle(.link)
                                    }
                                    Text("Processing continues while you navigate. Open the recording to cancel.").font(.caption).foregroundStyle(.secondary)
                                }.padding().frame(maxWidth: 360)
                            }
                    }
                }
                ToolbarItem {
                    Menu("View", systemImage: "line.3.horizontal.decrease") {
                        Toggle("Show recording cost", isOn: $showsCost)
                        Button("Usage & Cost…") { showsUsage = true }
                    }
                }
                ToolbarItem {
                    Button("New Project", systemImage: "folder.badge.plus") { editingProject = nil; showsProjectEditor = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(activeImportProject == nil ? "Import Audio" : "Import Files", systemImage: "square.and.arrow.down", action: showImporter)
                        .disabled(model.isImporting)
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.isImporting, !urls.isEmpty else { return false }
                importURLs(urls)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .focusedSceneValue(\.importAudio, importAction)
            .focusedSceneValue(\.newProject, { editingProject = nil; showsProjectEditor = true })
    }

    private var recordingRepository: SwiftDataRecordingRepository {
        SwiftDataRecordingRepository(context: modelContext, storage: model.projectImports.storage)
    }

    private var projectRepository: SwiftDataProjectRepository {
        SwiftDataProjectRepository(context: modelContext, storage: model.projectImports.storage)
    }

    private var promptTitle: String {
        switch model.prompt {
        case .renameRecording: "Rename Workspace"
        case .deleteRecording: "Delete Workspace?"
        case .deleteProject: "Delete Project?"
        case nil: ""
        }
    }

    @ViewBuilder private func promptActions(_ prompt: LibraryPrompt) -> some View {
        switch prompt {
        case .renameRecording(let recording):
            TextField("Name", text: $model.renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.confirmRename(recording, using: recordingRepository) }
                .disabled(model.renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .deleteRecording(let recording):
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { model.confirmDelete(recording, using: recordingRepository) }
        case .deleteProject(let project):
            Button("Cancel", role: .cancel) {}
            Button("Keep Recordings and Delete Project", role: .destructive) { deleteProject(project, deletingRecordings: false) }
            if !project.recordings.isEmpty {
                Button("Delete Recordings and Project", role: .destructive) { deleteProject(project, deletingRecordings: true) }
                    .disabled(project.recordings.contains(where: { !model.canDelete($0) }))
            }
        }
    }

    @ViewBuilder private func promptMessage(_ prompt: LibraryPrompt) -> some View {
        switch prompt {
        case .renameRecording: EmptyView()
        case .deleteRecording(let recording):
            Text("“\(recording.title)” and its imported files, transcripts, summaries, chats, and usage history will be permanently deleted. Original files remain on your Mac.")
        case .deleteProject(let project):
            Text("“\(project.name)” and its \(project.sources.count) shared sources will be permanently deleted. Keeping recordings makes them standalone and preserves their files, transcripts, summaries, chats and history. Project imports and extraction will be cancelled before deletion.")
        }
    }

    private func deleteProject(_ project: Project, deletingRecordings: Bool) {
        Task { await model.confirmDeleteProject(project, deletingRecordings: deletingRecordings, context: modelContext) }
    }

    private var importAction: (() -> Void)? {
        guard !model.isImporting else { return nil }
        return { showImporter() }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("Library") { Label("All Recordings", systemImage: "waveform").tag(LibraryDestination.allRecordings) }
            Section("Projects") {
                ForEach(projects) { project in
                    ProjectSidebarRow(project: project,
                        importURLs: { urls in Task { await model.importFiles(urls, to: project, context: modelContext) } },
                        moveRecordingIDs: { move($0, to: project) })
                        .tag(LibraryDestination.project(project.id))
                        .contextMenu {
                            Button("Rename…") { editingProject = project; showsProjectEditor = true }
                            Button("Import Files…") { showImporter(for: project) }
                            Button("Delete…", role: .destructive) { model.requestDeleteProject(project) }.disabled(model.isDeletingProject)
                        }
                }
                Button("New Project…", systemImage: "plus") { editingProject = nil; showsProjectEditor = true }
            }
            Section("Recent Recordings") {
                ForEach(Array(recordings.prefix(8))) { recording in
                    VStack(alignment: .leading, spacing: 5) {
                        if showsCost {
                            Text(costs.byRecording[recording.id]?.displayText ?? "Cost unavailable")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Label(recording.title, systemImage: "waveform")
                            .lineLimit(1)
                        if let transcription = model.activeTranscriptionModel(for: recording) {
                            Text("Transcribing · \(transcription.progressSnapshot?.currentPart ?? 1) of \(transcription.progressSnapshot?.totalParts ?? 1)")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(recording.importedAt, format: .dateTime.month(.abbreviated).day().year())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(LibraryDestination.recording(recording.id))
                    .draggable(RecordingDragItem(recordingID: recording.id)) {
                        Label(recording.title, systemImage: "waveform").padding(10)
                    }
                    .help("Drag this recording onto a project to move it without importing again")
                    .contextMenu {
                        Button("Open") { model.selectRecording(recording.id) }
                        RecordingProjectMenu(recording: recording, projects: projects) { move(recording, to: $0) }
                        Button("Rename…", systemImage: "pencil") { model.requestRename(recording) }
                        Button("Reveal in Finder", systemImage: "folder") {
                            let urls = model.urlsToReveal(for: recording)
                            if !urls.isEmpty { Workspace.revealInFinder(urls) }
                        }
                        Divider()
                        Button("Delete…", systemImage: "trash", role: .destructive) { model.requestDelete(recording) }
                        .disabled(!model.canDelete(recording))
                    }
                }
            }
        }
        .navigationTitle("AudioNotes")
        .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if showsCost {
                    Text("Tracked API usage: \(costs.total.displayText)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("\(recordings.count) recordings").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Usage & Cost", systemImage: "dollarsign.circle") { showsUsage = true }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Library Usage & Cost")
                    if model.isImporting { ProgressView().controlSize(.small) }
                    Button(action: showImporter) { Image(systemName: "plus") }
                        .help("Import audio (⌘O)").accessibilityLabel("Import audio")
                        .disabled(model.isImporting)
                }
            }.padding(12)
        }
    }

    private func move(_ recording: Recording, to project: Project?) {
        model.move(recording, to: project, using: projectRepository)
    }

    private func move(_ recordingIDs: [UUID], to project: Project) {
        model.moveRecordings(recordingIDs, to: project, from: recordings, using: projectRepository)
    }

    private func showImporter() { showImporter(for: activeImportProject) }

    private func showImporter(for project: Project?) {
        guard !model.isImporting else { return }
        Task { @MainActor in
            let urls = await FilePanels.chooseFiles(
                title: project == nil ? "Import Audio" : "Import Files to " + (project?.name ?? ""), prompt: "Import",
                types: project == nil ? [.audio] : SourceImportService.supportedTypes)
            guard !urls.isEmpty else { return }
            if let project { await model.importFiles(urls, to: project, context: modelContext) }
            else { importURLs(urls) }
        }
    }

    private func importURLs(_ urls: [URL]) {
        let project = activeImportProject
        Task { await model.importFiles(urls, to: project, context: modelContext) }
    }
}
