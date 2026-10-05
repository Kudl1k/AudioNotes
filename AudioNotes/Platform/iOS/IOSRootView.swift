#if os(iOS)
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct IOSRootView: View {
    let services: AppServices
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Recording.importedAt, order: .reverse) private var recordings: [Recording]
    @Query(sort: \Project.name) private var projects: [Project]

    @Environment(\.modelContext) private var context
    @State private var imports = IOSAudioImportModel()
    @State private var showingImporter = false
    @State private var showingNewProject = false

    @State private var navigationPath: [LibraryDestination] = []
    @State private var destination: LibraryDestination? = .allRecordings
    @State private var isShowingSettings = false

    private var libraryPresentation: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .environment(imports)
#if DEBUG
        .task { await prepareReview() }
#endif
        .safeAreaInset(edge: .bottom) {
            if imports.isImporting {
                OperationProgressView(title: imports.isCancelling ? "Cancelling import…" : "Importing \(imports.currentFile) of \(imports.totalFiles)",
                                      startedAt: imports.startedAt, cancel: imports.cancel, canCancel: !imports.isCancelling)
                    .padding().background(.regularMaterial)
            }
        }
        .alert("Audio Import", isPresented: Binding(get: { imports.resultMessage != nil }, set: { if !$0 { imports.resultMessage = nil } })) {
            Button("OK") { imports.resultMessage = nil }
        } message: { Text(imports.resultMessage ?? "") }
    }

    var body: some View {
        libraryPresentation
        .onChange(of: navigationPath) { _, path in
            if horizontalSizeClass == .compact { destination = path.last ?? .allRecordings }
        }
        .onChange(of: horizontalSizeClass) { _, size in
            if size == .compact {
                navigationPath = destination.map { $0 == .allRecordings ? [] : [$0] } ?? []
            }
        }
        .onChange(of: imports.library.projectSelection) { _, id in
            guard let id else { return }
            destination = .project(id)
            if horizontalSizeClass == .compact { navigationPath = [.project(id)] }
        }
        .onChange(of: imports.library.selection) { _, id in
            guard let id else { return }
            destination = .recording(id)
            if horizontalSizeClass == .compact { navigationPath = [.recording(id)] }
        }
        .onChange(of: projects.map(\.id)) { _, ids in
            if case .project(let id) = destination, !ids.contains(id) { destination = .allRecordings; navigationPath = [] }
        }
        .alert("Library could not be updated", isPresented: Binding(get: { imports.library.error != nil }, set: { if !$0 { imports.library.error = nil } })) {
            Button("OK") { imports.library.error = nil }
        } message: { Text(imports.library.error?.message ?? "") }
        .onChange(of: recordings.map(\.id)) { _, ids in
            if case .recording(let id) = destination, !ids.contains(id) { destination = .allRecordings; navigationPath = [] }
        }
        .sheet(isPresented: $showingNewProject) { IOSProjectNameSheet(library: imports.library) }
        .sheet(isPresented: $isShowingSettings) {
            IOSSettingsView(services: services)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: SourceImportService.supportedTypes.filter { $0.conforms(to: .audio) }, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): imports.start(urls, context: context)
            case .failure: imports.pickerFailed()
            }
        }
        .environment(\.openSettingsAction, OpenSettingsAction {
            isShowingSettings = true
        })
    }

#if DEBUG
    private func prepareReview() async {
            do {
                guard ProcessInfo.processInfo.arguments.contains("--performance-fixtures") else { return }
                services.configuration.selectedProvider = .mock
                services.llmConfiguration.summaryProvider = .mock
                services.llmConfiguration.chatProvider = .mock
                if ProcessInfo.processInfo.arguments.contains("--ios-project-knowledge-review") {
                    try IOSProjectKnowledgeFixtures.prepare(context: context)
                    let project = try context.fetch(FetchDescriptor<Project>()).first { $0.id == IOSProjectKnowledgeFixtures.projectID }
                    if let project {
                        if ProcessInfo.processInfo.arguments.contains("--ios-project-import-progress") {
                            imports.library.projectImports.prepareReviewProgress(projectID: project.id)
                        }
                        destination = .project(project.id)
                        if horizontalSizeClass == .compact { navigationPath = [.project(project.id)] }
                    }
                    try Data("ready".utf8).write(to: AppStorageLocations.applicationSupport().appending(path: "ios-project-knowledge-review-ready"), options: .atomic)
                    return
                }
                guard ProcessInfo.processInfo.arguments.contains("--ios-audio-review") else { return }
                try await IOSAudioRecordingFixtures.prepare(context: context)
                if ProcessInfo.processInfo.arguments.contains("--ios-review-detail"), let recording = try context.fetch(FetchDescriptor<Recording>()).first { destination = .recording(recording.id); navigationPath = [.recording(recording.id)] }
                if ProcessInfo.processInfo.arguments.contains("--ios-review-project"), let project = try context.fetch(FetchDescriptor<Project>()).first(where: { !$0.recordings.isEmpty }) {
                    destination = .project(project.id); navigationPath = [.project(project.id)]
                }
                if ProcessInfo.processInfo.arguments.contains("--ios-review-new-project") { showingNewProject = true }
                if ProcessInfo.processInfo.arguments.contains("--ios-review-settings") { isShowingSettings = true }
                try Data("ready".utf8).write(to: AppStorageLocations.applicationSupport().appending(path: "ios-ux-review-ready"), options: .atomic)
            }
            catch {
                if ProcessInfo.processInfo.arguments.contains("--ios-project-knowledge-review") {
                    imports.resultMessage = "Offline fixture error: \(error.localizedDescription)"
                } else {
                    imports.resultMessage = "The offline review fixture could not be prepared."
                }
            }
    }
#endif

    private var importButton: some View {
        Menu {
            Button("Import Audio", systemImage: "waveform") { showingImporter = true }
                .accessibilityIdentifier("library.import")
                .disabled(imports.isImporting)
            Button("New Project", systemImage: "folder.badge.plus") { showingNewProject = true }
                .accessibilityIdentifier("library.newProject")
        } label: { Label("Add to Library", systemImage: "plus") }
        .accessibilityIdentifier("library.add")
    }

    // MARK: - iPhone (Compact) Layout

    private var compactLayout: some View {
        NavigationStack(path: $navigationPath) {
            List {
                Section(header: Text("Projects")) {
                    if projects.isEmpty {
                        Text("No Projects")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(projects) { project in
                            NavigationLink(value: LibraryDestination.project(project.id)) {
                                HStack {
                                    Label(project.name, systemImage: "folder").lineLimit(2)
                                    Spacer()
                                    Text("\(project.recordings.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .modifier(IOSProjectActions(project: project))
                        }
                    }
                    Button("New Project…", systemImage: "folder.badge.plus") { showingNewProject = true }
                }

                Section(header: Text("All Recordings")) {
                    if recordings.isEmpty {
                        VStack(alignment: .center, spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("No Recordings")
                                .font(.headline)
                            Text("Import audio to keep and play it in your library.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        Button("Import Audio", systemImage: "plus") { showingImporter = true }
                            .disabled(imports.isImporting)
                    } else {
                        ForEach(recordings) { recording in
                            NavigationLink(value: LibraryDestination.recording(recording.id)) {
                                IOSRecordingRow(recording: recording)
                            }
                            .modifier(IOSRecordingActions(recording: recording))
                        }
                    }
                }
            }
            .navigationDestination(for: LibraryDestination.self) { value in
                destinationView(value)
            }
            .navigationTitle("AudioNotes")
            .toolbar {
                if destination == .allRecordings || destination == nil {
                    ToolbarItem(placement: .topBarTrailing) { importButton }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: { isShowingSettings = true }) {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings").accessibilityIdentifier("library.settings")
                    }
                }
            }
        }
    }

    // MARK: - iPad (Regular) Layout

    private var regularLayout: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Section("Library") {
                    NavigationLink(value: LibraryDestination.allRecordings) {
                        Label("All Recordings", systemImage: "waveform")
                            .badge(recordings.count)
                    }
                }

                Section("Projects") {
                    if projects.isEmpty {
                        Text("No Projects")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(projects) { project in
                            NavigationLink(value: LibraryDestination.project(project.id)) {
                                Label(project.name, systemImage: "folder")
                                    .badge(project.recordings.count)
                            }
                            .modifier(IOSProjectActions(project: project))
                        }
                    }
                    Button("New Project…", systemImage: "folder.badge.plus") { showingNewProject = true }
                }

                Section("Recordings") {
                    if recordings.isEmpty {
                        Text("No Recordings")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recordings) { recording in
                            NavigationLink(value: LibraryDestination.recording(recording.id)) {
                                IOSRecordingRow(recording: recording)
                            }
                        }
                    }
                }
            }
            .navigationTitle("AudioNotes")
            .toolbar {
                if destination == .allRecordings || destination == nil {
                    ToolbarItem(placement: .topBarTrailing) { importButton }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: { isShowingSettings = true }) {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings").accessibilityIdentifier("library.settings")
                    }
                }
            }
        } detail: {
            NavigationStack { detailContent }
        }
    }

    private var detailContent: some View { destinationView(destination) }

    @ViewBuilder private func destinationView(_ value: LibraryDestination?) -> some View {
        switch value {
        case .recording(let id):
            if let recording = recordings.first(where: { $0.id == id }) {
                IOSRecordingDetailShell(recording: recording, services: services,
                    transcriptionModel: imports.library.transcriptionModel(for: recording, resolver: IOSFeatureProviders.transcription(services)),
                    summaryModel: imports.library.summaryModel(for: recording, resolver: IOSFeatureProviders.llm(services)),
                    chatModel: imports.library.chatModel(for: recording, resolver: IOSFeatureProviders.llm(services)),
                    projectCitation: imports.library.pendingProjectCitation).id(recording.id)
            } else {
                ContentUnavailableView("Recording Not Found", systemImage: "waveform.slash",
                                       description: Text("The selected recording could not be found."))
            }
        case .project(let id):
            if let project = projects.first(where: { $0.id == id }) {
                IOSProjectWorkspaceShell(project: project, services: services)
            } else {
                ContentUnavailableView("Project Not Found", systemImage: "folder.badge.questionmark",
                                       description: Text("The selected project could not be found."))
            }
        case .allRecordings, .none:
            if recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Recordings", systemImage: "waveform")
                } description: {
                    Text("Import audio to keep and play it in your library.")
                } actions: {
                    Button("Import Audio", systemImage: "plus") { showingImporter = true }
                        .buttonStyle(.borderedProminent).disabled(imports.isImporting)
                }
                .navigationTitle("All Recordings")
            } else {
                List(recordings) { recording in
                    Button(action: { destination = .recording(recording.id) }) {
                        HStack {
                            IOSRecordingRow(recording: recording)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(IOSRecordingActions(recording: recording))
                }
                .navigationTitle("All Recordings")
            }
        }
    }
}
#endif
