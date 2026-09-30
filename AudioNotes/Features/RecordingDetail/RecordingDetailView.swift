import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    @State private var playback = AudioPlaybackService()
    @State private var showsChat = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(recording.title).font(.largeTitle.bold()).textSelection(.enabled)
                HStack {
                    Label(recording.originalFileName, systemImage: "music.note")
                    Text("•")
                    Text(recording.importedAt, format: .dateTime.month().day().year())
                }
                .font(.subheadline).foregroundStyle(.secondary)
                PlaybackControls(playback: playback)
                    .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            Divider()
            TabView {
                Tab("Summary", systemImage: "doc.text") {
                    SummaryView(summary: recording.summary)
                }
                Tab("Transcript", systemImage: "text.alignleft") {
                    TranscriptView(transcript: recording.transcript) { playback.seek(to: $0) }
                }
            }
            .padding(16)
        }
        .navigationTitle(recording.title)
        .toolbar {
            ToolbarItem {
                Button("Chat", systemImage: "sidebar.right") { showsChat.toggle() }
                    .help(showsChat ? "Hide chat" : "Show chat")
            }
        }
        .inspector(isPresented: $showsChat) {
            ChatInspectorView(recording: recording)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 440)
        }
        .onAppear { playback.load(url: LibraryStorage().recordingURL(fileName: recording.audioFileName)) }
        .onDisappear { playback.stop() }
    }
}
