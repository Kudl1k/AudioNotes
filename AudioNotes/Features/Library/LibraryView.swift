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
    @State private var showsPackageImporter = false
    @State private var driveSharingRequest: DriveSharingRequest?
    @State private var showsFolderImporter = false
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

    private struct DriveSharingRequest: Identifiable {
        let id = UUID()
        let projectID: UUID?
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
                    moveToProject: { move(selectedRecording, to: $0) },
                    renameRecording: { model.requestRename(selectedRecording) }
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

    private var sharingPresentation: some View {
        navigation
            .modifier(RecordingPackageImportModifier(isPresented: $showsPackageImporter,
                storage: model.projectImports.storage, onImported: { model.selectRecording($0) }))
            .sheet(item: $driveSharingRequest) { request in
                DriveProjectsSheet(storage: model.projectImports.storage, initialProject: request.projectID)
            }
            .sheet(isPresented: $showsFolderImporter) {
                ImportRecordingFolderSheet(storage: model.projectImports.storage) { model.selectRecording($0) }
            }
    }

    var body: some View {
        sharingPresentation
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
            .toolbar { libraryToolbar }
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
            .focusedSceneValue(\.librarySharing, LibrarySharingCommands(
                importFile: { showsPackageImporter = true },
                importFolder: { showsFolderImporter = true },
                shareProjects: { showDriveSharing(for: selectedProject?.id) }
            ))
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
                    SidebarRecordingRow(
                        recording: recording,
                        transcription: model.existingTranscriptionModel(for: recording),
                        costText: showsCost ? costs.byRecording[recording.id]?.compactDisplayText : nil
                    )
                    .accessibilityIdentifier("sidebar.recording.\(recording.id.uuidString)")
                    .tag(LibraryDestination.recording(recording.id))
                    .draggable(RecordingDragItem(recordingID: recording.id)) {
                        Label(recording.title, systemImage: "waveform").padding(10)
                    }
                    .help(RecordingRowPresentation.helpText(for: recording))
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
        .navigationTitle("Soniquill")
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
                    Menu {
                        Button("Usage & Cost…", systemImage: "dollarsign.circle") { showsUsage = true }
                        Divider()
                        Toggle("Show Recording Cost", isOn: $showsCost)
                    } label: {
                        Image(systemName: "dollarsign.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Library Usage & Cost")
                    .accessibilityLabel("Usage & Cost")
                    .accessibilityIdentifier("sidebar.usage")
                    if model.isImporting { ProgressView().controlSize(.small).accessibilityLabel("Importing") }
                    Button(action: showImporter) { Image(systemName: importSymbol) }
                        .buttonStyle(.borderless)
                        .help(activeImportProject == nil ? "Import Audio (⌘O)" : "Import Files (⌘O)")
                        .accessibilityLabel(activeImportProject == nil ? "Import Audio" : "Import Files")
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

    private func activityPopover(operations: [LibraryActivity], activeCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Text("\(activeCount) active")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(operations) { activity in
                        activityRow(activity.recordingTitle, status: activity.operation, icon: "waveform") {
                            model.selectRecording(activity.recordingID)
                        }
                    }
                    ForEach(projects.filter { model.projectImports.hasJobs(for: $0.id) }) { project in
                        activityRow(project.name, status: "Importing files", icon: "folder") {
                            model.selectProject(project.id)
                        }
                    }
                }
            }
            .frame(maxHeight: 250)
            .fixedSize(horizontal: false, vertical: true)

        }
        .padding(14)
        .frame(width: 330)
    }

    private func activityRow(_ name: String, status: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            showsActivity = false
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityValue(status)
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            let operations = model.activeOperations
            let imports = model.projectImports.items.filter(\.isActive)
            let activeCount = operations.count + imports.count
            if activeCount > 0 {
                Button {
                    showsActivity.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(activeCount, format: .number)
                            .monospacedDigit()
                    }
                }
                .help("Background activity")
                .accessibilityLabel("Background activity")
                .accessibilityValue("\(activeCount) active")
                .popover(isPresented: $showsActivity) {
                    activityPopover(operations: operations, activeCount: activeCount)
                }
            }
        }

        if selectedRecording == nil {
            ToolbarItemGroup(placement: .primaryAction) {
                if selectedProject == nil {
                    Button {
                        editingProject = nil
                        showsProjectEditor = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.badge.plus")
                            Text("New Project")
                        }
                    }
                    .help("Create a new project")
                    .accessibilityIdentifier("toolbar.newProject")
                }

                Button(action: showImporter) {
                    HStack(spacing: 5) {
                        Image(systemName: selectedProject == nil ? "waveform.badge.plus" : "plus")
                        Text(selectedProject == nil ? "Import Audio" : "Import Files")
                    }
                }
                .help(selectedProject == nil ? "Import audio into library (⌘O)" : "Import audio or documents into project (⌘O)")
                .disabled(model.isImporting)
                .accessibilityIdentifier("import.files")
            }
        }
    }

    private var importSymbol: String { activeImportProject == nil ? "waveform.badge.plus" : "doc.badge.plus" }

    private func showDriveSharing(for id: UUID? = nil) {
        driveSharingRequest = DriveSharingRequest(projectID: id)
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

struct SidebarRecordingRow: View {
    let recording: Recording
    let transcription: RecordingViewModel?
    let costText: String?

    private var activeStatusText: String? {
        guard let transcription, transcription.state.isProcessing else { return nil }
        return RecordingRowPresentation.activeTranscriptionText(for: transcription)
    }

    private var isFailed: Bool {
        guard let transcription else { return false }
        if case .failed = transcription.state { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: recording.audioFileName.isEmpty ? "doc.text" : "waveform")
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(RecordingRowPresentation.metadataText(for: recording, costText: costText))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let project = recording.project {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .imageScale(.small)
                        Text(project.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if activeStatusText == nil, !isFailed, recording.transcript != nil {
                            Text("· Transcribed")
                                .layoutPriority(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if activeStatusText == nil, !isFailed, recording.transcript != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "text.alignleft")
                            .imageScale(.small)
                        Text("Transcribed")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let activeStatusText {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                        Text(activeStatusText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if isFailed {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .imageScale(.small)
                        Text("Transcription failed")
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

enum RecordingRowPresentation {
    static func importedDateText(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today, \(date.formatted(date: .omitted, time: .shortened))"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    @MainActor
    static func metadataText(for recording: Recording, costText: String?, now: Date = .now, calendar: Calendar = .current) -> String {
        var parts = [importedDateText(recording.importedAt, now: now, calendar: calendar)]
        if recording.audioFileName.isEmpty {
            parts.append("Workspace")
        } else if recording.duration > 0 {
            parts.append(AudioTime.string(recording.duration))
        }
        if let costText {
            parts.append(costText)
        }
        return parts.joined(separator: " · ")
    }

    @MainActor
    static func activeTranscriptionText(for model: RecordingViewModel) -> String {
        model.progressSnapshot?.partDescription.map { "Transcribing · \($0)" }
            ?? model.progressSnapshot?.phase.message
            ?? model.state.title
    }

    @MainActor
    static func helpText(for recording: Recording) -> String {
        var lines = [
            recording.title,
            "Added \(recording.importedAt.formatted(date: .abbreviated, time: .shortened))"
        ]
        if let project = recording.project {
            lines.append("Project: \(project.name)")
        }
        lines.append("Drag onto a project to move")
        return lines.joined(separator: "\n")
    }
}

#endif
