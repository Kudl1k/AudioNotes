import SwiftUI

struct ProjectChatSelectionView: View {
    @Bindable var model: ProjectChatViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search Sources").font(.title2.bold())
            Picker("Source scope", selection: $model.selection.entireProject) {
                Text("Entire Project").tag(true)
                Text("Selected Sources").tag(false)
            }.pickerStyle(.radioGroup)
            List {
                Section("Recordings · Transcript and attachments") {
                    ForEach(model.project.recordings.sorted { $0.title < $1.title }) { recording in
                        Toggle(recording.title, isOn: recordingBinding(recording.id))
                    }
                }
                Section("Project Sources") {
                    ForEach(model.project.sources.sorted { $0.displayName < $1.displayName }) { source in
                        Toggle(source.displayName, isOn: sourceBinding(source.id))
                    }
                }
            }.disabled(model.selection.entireProject)
            HStack {
                Button("Select All") {
                    model.selection.entireProject = false
                    model.selection.recordingIDs = Set(model.project.recordings.map(\.id))
                    model.selection.sharedSourceIDs = Set(model.project.sources.map(\.id))
                }
                Button("Clear") {
                    model.selection.entireProject = false
                    model.selection.recordingIDs = []; model.selection.sharedSourceIDs = []
                }
                Spacer()
                Button("Done") { model.saveSelection(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(minWidth: 440, minHeight: 420)
    }
    private func recordingBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { model.selection.recordingIDs.contains(id) }, set: { value in
            if value { model.selection.recordingIDs.insert(id) } else { model.selection.recordingIDs.remove(id) }
        })
    }
    private func sourceBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { model.selection.sharedSourceIDs.contains(id) }, set: { value in
            if value { model.selection.sharedSourceIDs.insert(id) } else { model.selection.sharedSourceIDs.remove(id) }
        })
    }
}
