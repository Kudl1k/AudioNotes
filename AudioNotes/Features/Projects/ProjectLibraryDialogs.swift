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
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showsEditor) {
                ProjectEditorView(project: editing) { name, description in
                    model.saveProject(editing, name: name, description: description, using: SwiftDataProjectRepository(context: context))
                }
            }
    }
}
