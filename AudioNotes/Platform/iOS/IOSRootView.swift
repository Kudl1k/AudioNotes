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

    @State private var destination: LibraryDestination? = .allRecordings
    @State private var isShowingSettings = false

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .environment(imports)
#if DEBUG
        .task {
            do { try await IOSAudioRecordingFixtures.prepare(context: context) }
            catch { imports.resultMessage = "The offline review fixture could not be prepared." }
        }
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
        .onChange(of: recordings.map(\.id)) { _, ids in
            if case .recording(let id) = destination, !ids.contains(id) { destination = .allRecordings }
        }
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

    private var importButton: some View {
        Button("Import Audio", systemImage: "plus") { showingImporter = true }
            .disabled(imports.isImporting)
            .accessibilityIdentifier("library.import")
    }

    // MARK: - iPhone (Compact) Layout

    private var compactLayout: some View {
        NavigationStack {
            List {
                Section(header: Text("Projects")) {
                    if projects.isEmpty {
                        Text("No Projects")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(projects) { project in
                            NavigationLink(destination: IOSProjectWorkspaceShell(project: project)) {
                                HStack {
                                    Label(project.name, systemImage: "folder")
                                    Spacer()
                                    Text("\(project.recordings.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
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
                            NavigationLink(destination: IOSRecordingDetailShell(recording: recording)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recording.title)
                                        .lineLimit(2).truncationMode(.middle)
                                        .font(.body.weight(.medium))
                                    HStack(spacing: 6) {
                                        Text(AudioTime.format(recording.duration))
                                        Text("•")
                                        Text(recording.importedAt.formatted(date: .abbreviated, time: .shortened))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("AudioNotes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { importButton }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { isShowingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
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
                        }
                    }
                }

                Section("Recordings") {
                    if recordings.isEmpty {
                        Text("No Recordings")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recordings) { recording in
                            NavigationLink(value: LibraryDestination.recording(recording.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(recording.title)
                                        .lineLimit(2).truncationMode(.middle)
                                        .font(.body)
                                    Text("\(AudioTime.format(recording.duration)) • \(recording.importedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("AudioNotes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { importButton }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { isShowingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        } detail: {
            NavigationStack { detailContent }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch destination {
        case .recording(let id):
            if let recording = recordings.first(where: { $0.id == id }) {
                IOSRecordingDetailShell(recording: recording).id(recording.id)
            } else {
                ContentUnavailableView("Recording Not Found", systemImage: "waveform.slash",
                                       description: Text("The selected recording could not be found."))
            }
        case .project(let id):
            if let project = projects.first(where: { $0.id == id }) {
                IOSProjectWorkspaceShell(project: project)
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
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recording.title)
                                        .lineLimit(2).truncationMode(.middle)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                HStack(spacing: 6) {
                                    Text(AudioTime.format(recording.duration))
                                    Text("•")
                                    Text(recording.importedAt.formatted(date: .abbreviated, time: .shortened))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .navigationTitle("All Recordings")
            }
        }
    }
}
#endif
