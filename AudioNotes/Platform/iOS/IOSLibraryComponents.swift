#if os(iOS)
import SwiftUI
import SwiftData

struct IOSRecordingRow: View {
    let recording: Recording
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(recording.title).font(.body.weight(.medium)).lineLimit(2)
            Text("\(AudioTime.format(recording.duration)) · \(recording.importedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

struct IOSProjectNameSheet: View {
    var project: Project?
    let library: LibraryViewModel
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name).focused($focused)
                    .submitLabel(.done).onSubmit(save)
                    .accessibilityIdentifier("project.name")
                if let error = library.error { Text(error.message).foregroundStyle(.secondary) }
            }
            .navigationTitle(project == nil ? "New Project" : "Rename Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(project == nil ? "Create" : "Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("project.save")
                }
            }
            .onAppear { name = project?.name ?? ""; focused = true }
        }
        .presentationDetents([.height(240), .medium, .large])
        .presentationDragIndicator(.visible)
    }
    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        library.error = nil
        library.saveProject(project, name: name, description: project?.projectDescription,
                            using: SwiftDataProjectRepository(context: context))
        if library.error == nil { dismiss() }
    }
}

struct IOSMoveRecordingSheet: View {
    let recording: Recording
    let library: LibraryViewModel
    @Query(sort: \Project.name) private var projects: [Project]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                destination("Library", project: nil)
                ForEach(projects) { destination($0.name, project: $0) }
            }
            .navigationTitle("Move to Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .accessibilityIdentifier("recording.projectPicker")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private func destination(_ name: String, project: Project?) -> some View {
        Button {
            library.error = nil
            library.move(recording, to: project, using: SwiftDataProjectRepository(context: context))
            if library.error == nil { dismiss() }
        } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if recording.project?.id == project?.id { Image(systemName: "checkmark") }
            }
        }
        .accessibilityValue(recording.project?.id == project?.id ? "Selected" : "")
    }
}

struct IOSProjectActions: ViewModifier {
    let project: Project
    var showsToolbar = false
    @Environment(IOSAudioImportModel.self) private var imports
    @Environment(\.modelContext) private var context
    @State private var rename = false
    @State private var delete = false
    func body(content: Content) -> some View {
        content
            .contextMenu { actions }
            .toolbar {
                if showsToolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu { actions } label: { Label("Project actions", systemImage: "ellipsis.circle") }
                            .accessibilityIdentifier("project.actions")
                    }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { actions }
            .sheet(isPresented: $rename) { IOSProjectNameSheet(project: project, library: imports.library) }
            .confirmationDialog("Delete \(project.name)?", isPresented: $delete, titleVisibility: .visible) {
                Button("Delete Project, Keep Recordings", role: .destructive) { remove(false) }
                Button("Delete Project and Recordings", role: .destructive) { remove(true) }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Project sources and project chat will be deleted. Choose whether to keep its recordings in the library.") }
            .onChange(of: delete) { _, presented in
                if !presented, case .deleteProject(let pending) = imports.library.prompt, pending.id == project.id {
                    imports.library.prompt = nil
                }
            }
    }
    @ViewBuilder private var actions: some View {
        Button("Rename", systemImage: "pencil") { rename = true }
        Button("Delete", systemImage: "trash", role: .destructive) {
            imports.library.requestDeleteProject(project)
            delete = true
        }
            .disabled(imports.library.isDeletingProject)
    }
    private func remove(_ recordings: Bool) {
        Task { await imports.library.confirmDeleteProject(project, deletingRecordings: recordings, context: context) }
    }
}

struct IOSRecordingActions: ViewModifier {
    let recording: Recording
    @Environment(IOSAudioImportModel.self) private var imports
    @Environment(\.modelContext) private var context
    @State private var move = false
    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Move to Project…", systemImage: "folder") { move = true }
            if recording.project != nil {
                Button("Remove from Project", systemImage: "folder.badge.minus") {
                    imports.library.move(recording, to: nil, using: SwiftDataProjectRepository(context: context))
                }
            }
        }
        .swipeActions(edge: .leading) { Button("Move", systemImage: "folder") { move = true }.tint(.blue) }
        .sheet(isPresented: $move) { IOSMoveRecordingSheet(recording: recording, library: imports.library) }
    }
}
#endif
