#if os(iOS)
import SwiftUI

struct IOSProjectWorkspaceShell: View {
    let project: Project
    let services: AppServices
    @Environment(IOSAudioImportModel.self) private var imports

    var body: some View {
        List {
            if let description = project.projectDescription, !description.isEmpty {
                Section { Text(description).foregroundStyle(.secondary) }
            }
            Section {
                NavigationLink {
                    List(project.recordings.sorted { $0.importedAt > $1.importedAt }) { recording in
                        NavigationLink {
                            IOSRecordingDetailShell(recording: recording, services: services,
                                transcriptionModel: imports.library.transcriptionModel(for: recording, resolver: IOSFeatureProviders.transcription(services)),
                                summaryModel: imports.library.summaryModel(for: recording, resolver: IOSFeatureProviders.llm(services)),
                                chatModel: imports.library.chatModel(for: recording, resolver: IOSFeatureProviders.llm(services)))
                        } label: { IOSRecordingRow(recording: recording) }
                        .modifier(IOSRecordingActions(recording: recording))
                    }
                    .overlay { if project.recordings.isEmpty { ContentUnavailableView("No Recordings", systemImage: "waveform", description: Text("Move recordings here from the library.")) } }
                    .navigationTitle("Recordings")
                } label: {
                    HStack {
                        Label("Recordings", systemImage: "waveform")
                        Spacer()
                        Text(project.recordings.count.formatted()).foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    List(project.sources) { source in Label(source.displayName, systemImage: "doc.text") }
                        .overlay { if project.sources.isEmpty { ContentUnavailableView("No Sources", systemImage: "doc.text", description: Text("Project document import is currently available on Mac.")) } }
                        .navigationTitle("Sources")
                } label: {
                    HStack {
                        Label("Sources", systemImage: "paperclip")
                        Spacer()
                        Text(project.sources.count.formatted()).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Created \(project.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    Text("Project Chat is available on Mac. Recording Chat is available inside each recording.")
                }
            }
        }
        .modifier(IOSProjectActions(project: project, showsToolbar: true))
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
