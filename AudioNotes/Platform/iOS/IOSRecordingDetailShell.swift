#if os(iOS)
import SwiftUI
import SwiftData
import AVFoundation

/// Native compact/regular detail; playback observation is confined to its control leaf.
struct IOSRecordingDetailShell: View {
    let recording: Recording
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(IOSAudioImportModel.self) private var imports
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = IOSRecordingPlaybackModel()
    @State private var tab = DetailTab.transcript
    @State private var showDelete = false
    @State private var showRename = false
    @State private var name = ""
    @State private var managementError: String?

    private enum DetailTab: String, CaseIterable { case transcript = "Transcript", summary = "Summary" }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recording.title).font(.title2.bold())
                        .lineLimit(3).truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    ViewThatFits(in: .horizontal) {
                        HStack { metadata }
                        VStack(alignment: .leading) { metadata }
                    }
                    if let project = recording.project {
                        Label(project.name, systemImage: "folder").font(.caption).lineLimit(2)
                    }
                    Text(recording.originalFileName).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            Picker("Recording content", selection: $tab) {
                ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Group {
                switch tab {
                case .transcript:
                    if let transcript = recording.transcript, !transcript.segments.isEmpty {
                        TranscriptView(transcript: transcript, seek: player.seek)
                    } else {
                        ContentUnavailableView("No transcript yet", systemImage: "text.alignleft",
                            description: Text("Your audio is ready to play. Transcription will be available in a future update."))
                    }
                case .summary:
                    IOSStoredSummaryView(recording: recording)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16).padding(.top, 12)
        .frame(maxWidth: 960).frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            IOSPlaybackControls(model: player).padding()
                .frame(maxWidth: 800).frame(maxWidth: .infinity).background(.regularMaterial)
        }
        .navigationTitle(recording.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") { name = recording.title; showRename = true }
                    Button("Delete Recording", systemImage: "trash", role: .destructive) { showDelete = true }
                } label: { Label("Recording actions", systemImage: "ellipsis.circle") }
            }
        }
        .alert("Rename Recording", isPresented: $showRename) {
            TextField("Recording name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                imports.library.error = nil
                imports.library.rename(recording, to: name, using: SwiftDataRecordingRepository(context: context))
                managementError = imports.library.error?.message
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete Recording?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete Recording", role: .destructive) {
                player.stop()
                imports.library.error = nil
                let deleted = imports.library.delete(recording, using: SwiftDataRecordingRepository(context: context))
                managementError = imports.library.error?.message
                if deleted { dismiss() }
            }
        } message: { Text("This removes the recording, its history, and managed files. The original file is kept.") }
        .alert("Recording could not be updated", isPresented: Binding(get: { managementError != nil }, set: { if !$0 { managementError = nil } })) {
            Button("OK") { managementError = nil }
        } message: { Text(managementError ?? "") }
        .task(id: recording.id) {
            await player.load(url: LibraryStorage().recordingURL(fileName: recording.audioFileName))
        }
        .onDisappear { player.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player.pause() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { player.handleInterruption($0) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { player.handleRouteChange($0) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
            player.stop()
            Task { await player.load(url: LibraryStorage().recordingURL(fileName: recording.audioFileName)) }
        }
    }

    @ViewBuilder private var metadata: some View {
        Label(OperationDurationFormatter.string(recording.duration), systemImage: "clock")
        Text(recording.importedAt.formatted(date: .abbreviated, time: .shortened))
            .foregroundStyle(.secondary)
    }
}

private struct IOSPlaybackControls: View {
    let model: IOSRecordingPlaybackModel
    @State private var scrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { scrubbing ? scrubTime : model.playback.currentTime }, set: {
                scrubTime = $0
                if !scrubbing { model.seek(to: $0) }
            }), in: 0...max(model.playback.duration, 0.01), onEditingChanged: { editing in
                if editing {
                    scrubTime = model.playback.currentTime
                    scrubbing = true
                } else {
                    model.seek(to: scrubTime)
                    scrubbing = false
                }
            })
            .disabled(!model.playback.isLoaded)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(OperationDurationFormatter.string(model.playback.currentTime)) of \(OperationDurationFormatter.string(model.playback.duration))")
            .accessibilityIdentifier("playback.position")
            HStack {
                Text(OperationDurationFormatter.string(scrubbing ? scrubTime : model.playback.currentTime))
                    .monospacedDigit().accessibilityLabel("Current position")
                    .accessibilityValue(OperationDurationFormatter.string(scrubbing ? scrubTime : model.playback.currentTime))
                Spacer()
                Button(action: model.togglePlayback) {
                    Label(model.playback.isPlaying ? "Pause" : "Play", systemImage: model.playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 80, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).disabled(!model.playback.isLoaded || model.isActivating)
                .accessibilityIdentifier("playback.toggle")
                Spacer()
                Text(OperationDurationFormatter.string(model.playback.duration))
                    .monospacedDigit().foregroundStyle(.secondary).accessibilityLabel("Duration")
                    .accessibilityValue(OperationDurationFormatter.string(model.playback.duration))
            }
            if let error = model.sessionError ?? model.playback.errorMessage {
                InlineErrorLabel(error)
            }
        }
        .onChange(of: model.playback.isPlaying) { _, playing in
            if !playing { model.pause() }
        }
    }
}
#endif
