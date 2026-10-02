#if os(macOS)
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
                    projectCitation: model.pendingProjectCitation,
                    projects: projects,
                    openProject: {
                        guard let project = selectedRecording.project else { return }
                        model.pendingProjectCitation = nil
                        model.selectProject(project.id)
                    },
                    moveToProject: { move(selectedRecording, to: $0) }
                )
                .id(selectedRecording.id)
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
                    if args.contains("--performance-long-names") {
                        model.selectProject(ProjectChatFixtures.longNamesProjectID)
                    } else if args.contains("--performance-project-chat") {
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
            .background(UsageSnapshotRefresher(costs: $costs).equatable())
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
                        .accessibilityIdentifier("toolbar.newProject")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(activeImportProject == nil ? "Import Audio" : "Import Files", systemImage: "square.and.arrow.down", action: showImporter)
                        .disabled(model.isImporting).accessibilityIdentifier("import.files")
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
            Section("Library") {
                Label("All Recordings", systemImage: "waveform").tag(LibraryDestination.allRecordings)
                    .accessibilityIdentifier("sidebar.allRecordings")
            }
            Section("Projects") {
                ForEach(projects) { project in
                    ProjectSidebarRow(project: project,
                        importURLs: { urls in Task { await model.importFiles(urls, to: project, context: modelContext) } },
                        moveRecordingIDs: { move($0, to: project) })
                        .tag(LibraryDestination.project(project.id))
                        .accessibilityIdentifier("sidebar.project.\(project.id.uuidString)")
                        .contextMenu {
                            Button("Rename…") { editingProject = project; showsProjectEditor = true }
                            Button("Import Files…") { showImporter(for: project) }
                            Button("Delete…", role: .destructive) { model.requestDeleteProject(project) }.disabled(model.isDeletingProject)
                        }
                }
                Button("New Project…", systemImage: "plus") { editingProject = nil; showsProjectEditor = true }
                    .accessibilityIdentifier("sidebar.newProject")
            }
            Section("Recent Recordings") {
                ForEach(Array(recordings.prefix(8))) { recording in
                    VStack(alignment: .leading, spacing: 5) {
                        if showsCost {
                            Text(costs.byRecording[recording.id]?.displayText ?? "Cost unavailable")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Label(recording.title, systemImage: "waveform")
                            .lineLimit(1).truncationMode(.middle)
                        if let transcription = model.activeTranscriptionModel(for: recording) {
                            Text(transcription.progressSnapshot?.partDescription.map { "Transcribing · \($0)" }
                                ?? transcription.progressSnapshot?.phase.message ?? transcription.state.title)
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(recording.importedAt, format: .dateTime.month(.abbreviated).day().year())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sidebar.recording.\(recording.id.uuidString)")
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
                    Text("^[\(recordings.count) recording](inflect: true)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Usage & Cost", systemImage: "dollarsign.circle") { showsUsage = true }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Library Usage & Cost")
                        .accessibilityIdentifier("sidebar.usage")
                    if model.isImporting { ProgressView().controlSize(.small).accessibilityLabel("Importing") }
                    Button(action: showImporter) { Image(systemName: "plus") }
                        .help("Import audio (⌘O)").accessibilityLabel("Import audio")
                        .accessibilityIdentifier("sidebar.import")
                        .disabled(model.isImporting)
                }
            }.padding(12).background(.bar)
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

#endif
