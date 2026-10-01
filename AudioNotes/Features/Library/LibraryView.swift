import AppKit
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
    @State private var deletingProject: Project?
    @State private var deletingProjectInProgress = false
    @State private var model = LibraryViewModel()
    @State private var isDropTargeted = false
    @State private var showsUsage = false
    @State private var showsActivity = false
    @SceneStorage("library.selection") private var restoredSelection = ""
    @State private var workspaceToRename: Recording?
    @State private var workspaceToDelete: Recording?
    @State private var workspaceTitle = ""
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
                    rename: { workspaceTitle = $0.title; workspaceToRename = $0 },
                    delete: { workspaceToDelete = $0 }, importAudio: showImporter)
            }
        }
    }

    var body: some View {
        navigation
            .modifier(ProjectLibraryDialogs(model: model, showsEditor: $showsProjectEditor, editing: $editingProject, deleting: $deletingProject, deletionInProgress: $deletingProjectInProgress))
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
            .alert("Rename Workspace", isPresented: Binding(
                get: { workspaceToRename != nil }, set: { if !$0 { workspaceToRename = nil } }
            )) {
                TextField("Name", text: $workspaceTitle)
                Button("Cancel", role: .cancel) { workspaceToRename = nil }
                Button("Rename") {
                    if let recording = workspaceToRename {
                        model.rename(recording, to: workspaceTitle, using: SwiftDataRecordingRepository(context: modelContext))
                    }
                    workspaceToRename = nil
                }
                .disabled(workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("Delete Workspace?", isPresented: Binding(
                get: { workspaceToDelete != nil }, set: { if !$0 { workspaceToDelete = nil } }
            )) {
                Button("Cancel", role: .cancel) { workspaceToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let recording = workspaceToDelete {
                        model.delete(recording, using: SwiftDataRecordingRepository(context: modelContext))
                    }
                    workspaceToDelete = nil
                }
            } message: {
                Text("“\(workspaceToDelete?.title ?? "")” and its imported files, transcripts, summaries, chats, and usage history will be permanently deleted. Original files remain on your Mac.")
            }
            .alert("Workspace could not be updated", isPresented: Binding(
                get: { model.workspaceError != nil }, set: { if !$0 { model.workspaceError = nil } }
            )) {
                Button("OK", role: .cancel) { model.workspaceError = nil }
            } message: {
                Text(model.workspaceError ?? "")
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
            .alert("Import could not be completed", isPresented: Binding(
                get: { model.importError != nil }, set: { if !$0 { model.importError = nil } }
            )) {
                Button("OK", role: .cancel) { model.importError = nil }
            } message: {
                Text(model.importError ?? "")
            }
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
                        importURLs: { model.projectImports.enqueue($0, to: project, context: modelContext) },
                        moveRecordingIDs: { move($0, to: project) })
                        .tag(LibraryDestination.project(project.id))
                        .contextMenu {
                            Button("Rename…") { editingProject = project; showsProjectEditor = true }
                            Button("Import Files…") { showImporter(for: project) }
                            Button("Delete…", role: .destructive) { deletingProject = project }.disabled(deletingProjectInProgress)
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
                        Button("Rename…", systemImage: "pencil") {
                            workspaceTitle = recording.title
                            workspaceToRename = recording
                        }
                        Button("Reveal in Finder", systemImage: "folder") {
                            let urls = model.revealURLs(for: recording)
                            if urls.isEmpty {
                                model.workspaceError = "This workspace has no available imported files to reveal."
                            } else {
                                NSWorkspace.shared.activateFileViewerSelecting(urls)
                            }
                        }
                        Divider()
                        Button("Delete…", systemImage: "trash", role: .destructive) {
                            workspaceToDelete = recording
                        }
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
        do { try SwiftDataProjectRepository(context: modelContext).move(recording, to: project) }
        catch { model.workspaceError = error.localizedDescription }
    }

    private func move(_ recordingIDs: [UUID], to project: Project) {
        let repository = SwiftDataProjectRepository(context: modelContext)
        for id in recordingIDs {
            guard let recording = recordings.first(where: { $0.id == id }), recording.project?.id != project.id else { continue }
            do { try repository.move(recording, to: project) }
            catch { model.workspaceError = error.localizedDescription; return }
        }
        model.selectProject(project.id)
    }

    private func showImporter() { showImporter(for: activeImportProject) }

    private func showImporter(for project: Project?) {
        guard !model.isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = project == nil ? "Import Audio" : "Import Files to " + (project?.name ?? "")
        panel.prompt = "Import"
        panel.allowedContentTypes = project == nil ? [.audio] : SourceImportService.supportedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        Task { @MainActor in
            if await panel.begin() == .OK {
                if let project, !project.isDeleted { model.projectImports.enqueue(panel.urls, to: project, context: modelContext) }
                else if project == nil { importURLs(panel.urls) }
            }
        }
    }

    private func importURLs(_ urls: [URL]) {
        if let project = activeImportProject {
            model.projectImports.enqueue(urls, to: project, context: modelContext)
            return
        }
        Task {
            await model.importURLs(urls, into: SwiftDataRecordingRepository(context: modelContext))
        }
    }
}
