#if os(iOS)
import SwiftUI

struct IOSLocalAISettingsView: View {
    let services: AppServices
    private func show(_ section: String) -> Bool {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--performance-fixtures"), let index = arguments.firstIndex(of: "--ios-local-ai-section"), arguments.indices.contains(index + 1) { return arguments[index + 1] == section }
#endif
        return true
    }
    private var languageStatus: String {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--performance-fixtures") { return "Ready · Synthetic review state · Managed by Apple Intelligence" }
#endif
        return SystemLocalLLMRuntime.availabilityDescription
    }
    var body: some View {
        Form {
            if show("overview") { Section {
                Toggle("Local Only", isOn: Binding(get: { services.llmConfiguration.localAI.localOnly },
                    set: { services.llmConfiguration.localAI.localOnly = $0 }))
                    .accessibilityIdentifier("localAI.localOnly")
            } footer: { Text("Blocks external AI providers. Downloading model data remains an explicit action. On-device processing never falls back to cloud automatically.") } }
            if show("transcription") { Section {
                ForEach(services.localAISettings.models) { model in
                    IOSWhisperModelRow(model: model, settings: services.localAISettings)
                }
            } header: { Text("Transcription") } footer: { Text("Start with Whisper Tiny. Base and Small need more storage and may use significant memory. Whisper provides timestamps and language detection, without speaker diarization.") } }
            if show("language") { Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalLLMProvider.modelTitle)
                    Text(languageStatus).font(.subheadline).foregroundStyle(.secondary)
                    Text("Summary · Recording Chat · Project Chat").font(.caption).foregroundStyle(.secondary)
                    Text("4,096-token context · Text only · No API charge").font(.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("localAI.languageModel")
            } header: { Text("Language Models") } footer: { Text("Apple manages this model through Apple Intelligence in system Settings. AudioNotes cannot download, delete, measure its storage, or select its version. Requires iOS 26 on an eligible device; enabling Apple Intelligence is your choice.") } }
            if show("storage") { Section("Storage") {
                LabeledContent("AudioNotes Models", value: services.localAISettings.storageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable")
                    .accessibilityIdentifier("localAI.storage")
                Text("Whisper models live in Application Support, are excluded from backups, and remain available offline until you delete them. Apple Intelligence storage is managed separately by iOS.")
                    .font(.footnote).foregroundStyle(.secondary)
            } }
        }
        .navigationTitle("Local AI").navigationBarTitleDisplayMode(.inline)
        .task {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--performance-fixtures") { return }
#endif
            await services.localAISettings.refreshInstalled()
        }
    }
}

/// Shared by Settings and the per-recording missing-model resolution surface.
struct IOSWhisperModelRow: View {
    let model: WhisperModelDescriptor
    @Bindable var settings: LocalAISettingsViewModel
    @State private var confirmRemoval = false
    private var installed: Bool { settings.installed.contains(model.id) }
    private var downloading: Bool { settings.downloadModelID == model.id }
    private var failed: Bool { settings.failedModelID == model.id }
    private var review: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--performance-fixtures")
#else
        false
#endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Whisper " + model.title).font(.body.weight(.medium))
            Text(status).font(.subheadline).foregroundStyle(.secondary)
            Text(model.id == "openai_whisper-tiny" ? "Start here · Smallest download" : "May use significant memory")
                .font(.caption).foregroundStyle(.secondary)
            if settings.failedModelID == nil, let error = settings.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if downloading, let progress = settings.progress {
                ProgressView(value: progress.fraction)
                    .accessibilityLabel("Downloading Whisper " + model.title)
                    .accessibilityValue(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file) + " of " + ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))
                    .accessibilityIdentifier("localAI.progress.\(model.id)")
                Text(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file) + " of " + ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel Download") { settings.cancelDownload() }
                    .accessibilityIdentifier("localAI.cancel.\(model.id)")
            } else if installed {
                Button("Delete Model", role: .destructive) { confirmRemoval = true }
                    .accessibilityIdentifier("localAI.delete.\(model.id)")
            } else {
                if failed, let error = settings.error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button(failed ? "Retry Download" : "Download Model") { settings.download(model) }
                    .disabled(!LocalAISettingsViewModel.supportsWhisper || settings.downloadModelID != nil)
                    .accessibilityIdentifier("localAI.download.\(model.id)")
            }
            Text("MIT · OpenAI Whisper / Argmax Core ML · " + model.id)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .disabled(review)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .confirmationDialog("Delete Whisper \(model.title)?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Delete Model", role: .destructive) { Task { await settings.remove(model) } }
        } message: { Text("Recordings, transcripts, summaries and chat history are preserved. Using this model again requires an explicit download.") }
    }
    private var status: String {
        let bytes = ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file)
        if downloading { return (settings.progress?.fraction == 1 ? "Verifying / Preparing" : "Downloading…") + " · " + bytes }
        if installed { return "Ready · " + bytes + " · On Device" }
        if failed { return "Download Failed · " + bytes }
        return "Not Downloaded · " + bytes
    }
}
#endif
