import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.importedAt, order: .reverse) private var recordings: [Recording]
    @State private var model = LibraryViewModel()
    @State private var isDropTargeted = false

    private var selectedRecording: Recording? { recordings.first { $0.id == model.selection } }

    private var navigation: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let selectedRecording {
                RecordingDetailView(recording: selectedRecording)
                    .id(selectedRecording.id)
            } else {
                ContentUnavailableView {
                    Label("Listen. Review. Reflect.", systemImage: "waveform.circle")
                } description: {
                    Text("Select a recording from your library, or import an audio file.")
                } actions: {
                    Button("Import Audio…", action: showImporter)
                        .disabled(model.isImporting)
                }
            }
        }
    }

    var body: some View {
        navigation
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Import Audio", systemImage: "square.and.arrow.down", action: showImporter)
                        .disabled(model.isImporting)
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.isImporting, !urls.isEmpty else { return false }
                importURLs(urls)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .focusedSceneValue(\.importAudio, importAction)
            .alert("Import could not be completed", isPresented: Binding(
                get: { model.importError != nil }, set: { if !$0 { model.importError = nil } }
            )) {
                Button("OK", role: .cancel) { model.importError = nil }
            } message: {
                Text(model.importError ?? "")
            }
    }

    private var importAction: (() -> Void)? {
        guard !model.isImporting else { return nil }
        return { showImporter() }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section("Recordings") {
                ForEach(recordings) { recording in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(recording.title, systemImage: "waveform")
                            .lineLimit(1)
                        Text(recording.importedAt, format: .dateTime.month(.abbreviated).day().year())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(recording.id)
                }
            }
        }
        .overlay {
            if recordings.isEmpty {
                ContentUnavailableView("Your audio library", systemImage: "waveform",
                                       description: Text("Import or drop audio files to get started."))
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle("AudioNotes")
        .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(recordings.count) recordings")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isImporting { ProgressView().controlSize(.small) }
                Button(action: showImporter) {
                    Image(systemName: "plus")
                }
                .help("Import audio (⌘I)")
                .accessibilityLabel("Import audio")
                .disabled(model.isImporting)
            }
            .padding(12)
        }
    }

    private func showImporter() {
        guard !model.isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        Task { @MainActor in
            if await panel.begin() == .OK { importURLs(panel.urls) }
        }
    }

    private func importURLs(_ urls: [URL]) {
        Task {
            await model.importURLs(urls, into: SwiftDataRecordingRepository(context: modelContext))
        }
    }
}
