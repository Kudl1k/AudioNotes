import SwiftUI

struct AllRecordingsView: View {
    let recordings: [Recording]
    let projects: [Project]
    let library: LibraryViewModel
    let showsCost: Bool
    let costs: UsageDashboardSnapshot
    let open: (Recording) -> Void
    let move: (Recording, Project?) -> Void
    let rename: (Recording) -> Void
    let delete: (Recording) -> Void
    let importAudio: () -> Void
    @State private var query = ""
    @State private var exporting: Recording?

    private var filtered: [Recording] {
        recordings.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("All Recordings").font(.title.bold())
                Spacer()
                TextField("Filter recording titles", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }.padding(20)
            if recordings.isEmpty {
                ContentUnavailableView {
                    Label("Your audio library", systemImage: "waveform")
                } description: { Text("Import audio or create a project to organize recordings and documents.") }
                actions: { Button("Import Audio…", action: importAudio) }
            } else {
                List(filtered) { recording in
                    Button { open(recording) } label: {
                        HStack {
                            Image(systemName: "waveform").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recording.title).foregroundStyle(.primary)
                                if showsCost {
                                    Text(costs.byRecording[recording.id]?.displayText ?? "Cost unavailable").font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text(AudioTime.string(recording.duration))
                                    if let project = recording.project { Text("· " + project.name) }
                                    if library.activeTranscriptionModel(for: recording) != nil { Text("· Transcribing") }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(recording.importedAt, format: .dateTime.month(.abbreviated).day().year()).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .draggable(RecordingDragItem(recordingID: recording.id)) {
                        Label(recording.title, systemImage: "waveform").padding(10)
                    }
                    .help("Drag this recording onto a project to move it without importing again")
                    .contextMenu {
                        Button("Open") { open(recording) }
                        Button("Rename…") { rename(recording) }
                        RecordingProjectMenu(recording: recording, projects: projects) { move(recording, $0) }
                        Button("Export…") { exporting = recording }
                        Button("Delete…", role: .destructive) { delete(recording) }.disabled(!library.canDelete(recording))
                    }
                }
            }
        }.sheet(item: $exporting) { ExportSheetView(recording: $0) }
    }
}
