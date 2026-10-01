import SwiftData
import SwiftUI

struct ProjectSidebarRow: View {
    let project: Project
    let importURLs: ([URL]) -> Void
    let moveRecordingIDs: ([UUID]) -> Void
    @State private var targeted = false
    @State private var recordingTargeted = false
    var body: some View {
        Label(project.name, systemImage: "folder").lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            .background(targeted || recordingTargeted ? Color.accentColor.opacity(0.15) : .clear)
            .accessibilityLabel("Project: " + project.name)
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                importURLs(urls)
                return true
            } isTargeted: { targeted = $0 }
            .dropDestination(for: RecordingDragItem.self) { items, _ in
                let ids = Array(Set(items.map(\.recordingID)))
                guard !ids.isEmpty else { return false }
                moveRecordingIDs(ids)
                return true
            } isTargeted: { recordingTargeted = $0 }
    }
}

struct ProjectLibraryDialogs: ViewModifier {
    let model: LibraryViewModel
    @Binding var showsEditor: Bool
    @Binding var editing: Project?
    @Binding var deleting: Project?
    @Binding var deletionInProgress: Bool
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showsEditor) {
                ProjectEditorView(project: editing) { name, description in
                    do {
                        let repository = SwiftDataProjectRepository(context: context)
                        if let editing { try repository.rename(editing, name: name, description: description) }
                        else { model.selectProject(try repository.create(name: name, description: description).id) }
                    } catch { model.workspaceError = error.localizedDescription }
                }
            }
            .alert("Delete Project?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Keep Recordings and Delete Project", role: .destructive) { delete(false) }
                if deleting?.recordings.isEmpty == false {
                    Button("Delete Recordings and Project", role: .destructive) { delete(true) }
                        .disabled(deleting?.recordings.contains(where: { !model.canDelete($0) }) == true)
                }
            } message: {
                Text("“\(deleting?.name ?? "")” and its \(deleting?.sources.count ?? 0) shared sources will be permanently deleted. Keeping recordings makes them standalone and preserves their files, transcripts, summaries, chats and history. Project imports and extraction will be cancelled before deletion.")
            }
    }
    private func delete(_ deleteRecordings: Bool) {
        guard let project = deleting, !deletionInProgress else { return }
        deleting = nil
        deletionInProgress = true
        Task {
            await model.deleteProject(project, deletingRecordings: deleteRecordings, context: context)
            deletionInProgress = false
        }
    }
}
