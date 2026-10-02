#if os(iOS)
import SwiftUI
import SwiftData

struct IOSRootView: View {
    let services: AppServices
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \Recording.importedAt, order: .reverse) private var recordings: [Recording]
    @Query(sort: \Project.name) private var projects: [Project]

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
        .sheet(isPresented: $isShowingSettings) {
            IOSSettingsView(services: services)
        }
        .environment(\.openSettingsAction, OpenSettingsAction {
            isShowingSettings = true
        })
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

                Section(header: Text("Recordings")) {
                    if recordings.isEmpty {
                        VStack(alignment: .center, spacing: 8) {
                            Image(systemName: "waveform")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("No Recordings")
                                .font(.headline)
                            Text("Recordings added to AudioNotes will appear here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(recordings) { recording in
                            NavigationLink(destination: IOSRecordingDetailShell(recording: recording)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recording.title)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { isShowingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        } detail: {
            detailContent
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch destination {
        case .recording(let id):
            if let recording = recordings.first(where: { $0.id == id }) {
                IOSRecordingDetailShell(recording: recording)
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
                ContentUnavailableView("No Recordings", systemImage: "waveform",
                                       description: Text("Recordings added to AudioNotes will appear here."))
            } else {
                List(recordings) { recording in
                    Button(action: { destination = .recording(recording.id) }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recording.title)
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
