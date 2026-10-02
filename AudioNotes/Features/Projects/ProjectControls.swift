import SwiftData
import SwiftUI

struct RecordingProjectMenu: View {
    let recording: Recording
    let projects: [Project]
    let move: (Project?) -> Void
    var body: some View {
        Menu("Move to Project") {
            ForEach(projects) { project in
                Button(project.name) { move(project) }.disabled(recording.project?.id == project.id)
            }
            if projects.isEmpty { Text("Create a project first") }
        }
        if recording.project != nil { Button("Remove from Project") { move(nil) } }
    }
}

struct ProjectEditorView: View {
    let project: Project?
    let save: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(project == nil ? "New Project" : "Edit Project").font(.headline)
            Form {
                TextField("Project Name", text: $name)
                TextField("Description (optional)", text: $description, axis: .vertical).lineLimit(3...5)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(project == nil ? "Create" : "Save") { save(name, description); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 420)
        .onAppear { name = project?.name ?? ""; description = project?.projectDescription ?? "" }
    }
}

struct ProjectImportActivityView: View {
    let projectID: UUID
    @Bindable var queue: ProjectImportQueue
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Activity").font(.headline)
            List(queue.items.filter { $0.projectID == projectID }) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Label(item.filename, systemImage: icon(item)).lineLimit(1)
                    Text(item.statusText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if item.state == .processing, let progress = item.progress, progress.total > 0 {
                        ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    }
                    if item.isActive, let started = item.startedAt {
                        Text(started, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .combine)
            }.frame(width: 380, height: 300)
            HStack {
                Button("Clear Finished") { queue.clearFinished(for: projectID) }
                Spacer()
                Button("Cancel Remaining") { queue.cancelRemaining(for: projectID) }.disabled(!queue.hasJobs(for: projectID))
            }
        }.padding()
    }
    private func icon(_ item: ProjectImportItem) -> String {
        switch item.state {
        case .added: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        case .waiting: "clock"
        case .importing, .processing: "arrow.triangle.2.circlepath"
        }
    }
}

