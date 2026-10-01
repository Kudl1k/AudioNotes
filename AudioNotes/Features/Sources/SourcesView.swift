import AppKit
import SwiftData
import SwiftUI

struct SourcesView: View {
    @Bindable var model: SourcesViewModel
    let transcriptionResolver: any TranscriptionProviderResolving
    let transcriptionModel: RecordingViewModel
    let primaryTranscriptionBusy: Bool
    let onPrimaryTranscribe: () -> Void
    let onReference: (SourceReference) -> Void
    @Environment(\.modelContext) private var context
    @State private var preview: SourcePreviewTarget?
    @State private var removing: RecordingSource?
    @State private var renaming: RecordingSource?
    @State private var newName = ""
    @State private var dropTargeted = false
    @State private var transcriptionOptionsSourceID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search all sources", text: $model.searchQuery).textFieldStyle(.roundedBorder)
                    .onChange(of: model.searchQuery) { _, _ in model.search() }
                Button("Add Source…", systemImage: "plus") { showImporter() }.disabled(model.isImporting)
                if model.isImporting { ProgressView().controlSize(.small) }
            }.padding(12)
            if let phase = model.importPhase { Text(phase).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            List {
                if model.searchQuery.isEmpty {
                    ForEach(model.recording.sources.sorted { $0.importedAt < $1.importedAt }) { source in
                        sourceRow(source)
                    }
                } else {
                    ForEach(model.searchResults) { chunk in
                        Button {
                            onReference(SourceReference(sourceID: chunk.sourceID, chunkID: chunk.id, sourceName: chunk.sourceName,
                                sourceType: chunk.sourceType, locator: chunk.locator, excerpt: String(chunk.text.prefix(160))))
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(chunk.sourceName + " · " + chunk.locator.locationLabel, systemImage: chunk.sourceType.icon).font(.headline)
                                Text(String(chunk.text.prefix(240))).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("Originals are stored locally. PDF extraction, OCR, and search have no API cost.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 3).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isImporting, !urls.isEmpty else { return false }
            Task { await model.importURLs(urls, context: context) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: $preview) { target in SourcePreviewView(target: target, url: model.url(for: target.source)) }
        .alert("Source import", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Rename Source", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Display name", text: $newName)
            Button("Rename") { if let renaming { model.rename(renaming, name: newName, context: context) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Remove Source?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Source", role: .destructive) { if let removing { model.remove(removing, context: context) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("The managed original, extracted text, and its clickable references will be deleted. The workspace and saved answers remain.") }
        .onAppear { model.prepare(context: context) }
    }

    private func sourceRow(_ source: RecordingSource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SourceThumbnailView(url: model.thumbnailURL(for: source), revision: source.statusRaw,
                icon: source.type.icon, loader: model.imageLoader)
            VStack(alignment: .leading, spacing: 5) {
                Text(source.displayName).font(.headline)
                Text(statusText(source)).font(.caption).foregroundStyle(.secondary)
                if let error = source.processingError { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                if let started = model.startedAt[source.id] {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Elapsed \(Int(max(0, timeline.date.timeIntervalSince(started))))s").font(.caption).foregroundStyle(.secondary)
                            if timeline.date.timeIntervalSince(started) > 15 && source.type != .audio {
                                Text("Local OCR can take longer on first use. You can continue using other ready sources or cancel.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Spacer()
            if model.isProcessing(source) {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancel(source) }
            } else if source.type == .audio, !source.isContextReady {
                Button("Transcribe…") { transcriptionOptionsSourceID = source.id }
                    .disabled(source.isPrimaryAudio && primaryTranscriptionBusy)
                    .popover(isPresented: Binding(
                        get: { transcriptionOptionsSourceID == source.id },
                        set: { if !$0 { transcriptionOptionsSourceID = nil } }
                    )) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Transcribe " + source.displayName).font(.headline)
                            TranscriptionProviderControls(model: transcriptionModel)
                            HStack {
                                Button("Cancel") { transcriptionOptionsSourceID = nil }
                                Spacer()
                                Button("Transcribe") {
                                    transcriptionOptionsSourceID = nil
                                    if source.isPrimaryAudio { onPrimaryTranscribe() }
                                    else {
                                        model.transcribe(source, resolver: transcriptionResolver, context: context,
                                            provider: transcriptionModel.selectedProvider, model: transcriptionModel.selectedModel)
                                    }
                                }.buttonStyle(.borderedProminent)
                            }
                        }.padding().frame(width: 390)
                    }
            } else if source.status == .failed || source.status == .partial {
                Button("Retry") { model.reprocess(source, context: context) }
            }
            Button("Open", systemImage: "eye") { preview = .init(source: source) }.labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Open") { preview = .init(source: source) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.url(for: source)]) }
            Button("Rename…") { renaming = source; newName = source.displayName }
            if source.type != .audio { Button("Reprocess") { model.reprocess(source, context: context) }.disabled(model.isProcessing(source)) }
            Divider()
            Button("Remove from Recording…", role: .destructive) { removing = source }
                .disabled(model.isProcessing(source) || (source.isPrimaryAudio && primaryTranscriptionBusy))
        }
    }
    private func statusText(_ source: RecordingSource) -> String {
        if let progress = model.progress[source.id] { return "\(progress.phase) · \(progress.completed) of \(progress.total)" }
        if source.type == .audio { return source.isContextReady ? "Transcribed" : "Audio · \(source.status.rawValue.capitalized)" }
        let prefix: String
        switch source.metadata {
        case .pdf(let count, _): prefix = "\(count) pages · "
        case .image(let width, let height): prefix = "\(width) × \(height) · "
        default: prefix = ""
        }
        return prefix + source.status.rawValue.capitalized
    }
    private func showImporter() {
        let panel = NSOpenPanel()
        panel.title = "Add Sources"
        panel.allowedContentTypes = SourceImportService.supportedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        Task { if await panel.begin() == .OK { await model.importURLs(panel.urls, context: context) } }
    }
}
