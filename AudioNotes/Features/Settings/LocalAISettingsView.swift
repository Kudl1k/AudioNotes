import SwiftUI

struct LocalAISettingsView: View {
    @Bindable var configuration: LocalAIConfiguration
    @Bindable var model: LocalAISettingsViewModel
    @State private var pendingDownload: WhisperModelDescriptor?
    @State private var pendingRemoval: WhisperModelDescriptor?
    init(model: LocalAISettingsViewModel) {
        self.configuration = model.configuration
        self.model = model
    }
    var body: some View {
        Group {
            Section("Ollama") {
                TextField("Server", text: $configuration.ollamaAddress)
                Text((try? OllamaEndpoint(configuration.ollamaAddress))?.executionLocation.title ?? "Invalid server address")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.connection).textSelection(.enabled)
                HStack {
                    Button("Test Connection / Refresh Models") { Task { await model.refreshOllama() } }.disabled(model.checking)
                    if model.checking { ProgressView().controlSize(.small) }
                    Link("Open Ollama Website", destination: URL(string: "https://ollama.com/download/mac")!)
                }
                Text("\(configuration.models.count) installed chat models available. AudioNotes does not install or start Ollama.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Context budget (tokens)", value: $configuration.contextTokens, format: .number)
                Text("Uses the smaller of this budget and the model's reported context window. Larger contexts require more memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Local Whisper · Runs on this Mac") {
                if LocalAISettingsViewModel.supportsWhisper {
                    Text("Core ML models are stored in AudioNotes Application Support. Smaller files use less disk space. Download size is shown before installation.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.models) { item in
                        HStack {
                            Text(item.title)
                            Text(ByteCountFormatter.string(fromByteCount: item.downloadBytes, countStyle: .file)).foregroundStyle(.secondary)
                            Spacer()
                            if model.installed.contains(item.id) {
                                Text("Installed").foregroundStyle(.secondary)
                                Button("Remove", role: .destructive) { pendingRemoval = item }.disabled(model.downloadModelID != nil)
                            } else if model.downloadModelID == item.id {
                                Text("Downloading…").foregroundStyle(.secondary)
                            } else {
                                Button("Download") { pendingDownload = item }.disabled(model.downloadModelID != nil)
                            }
                        }
                    }
                    if let progress = model.progress {
                        ProgressView(value: progress.fraction)
                        HStack {
                            Text("Downloading · \(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                            Spacer()
                            Button("Cancel", action: model.cancelDownload)
                        }.font(.caption)
                    }
                    if let error = model.error { Text("Download or model operation failed: " + error).foregroundStyle(.red).textSelection(.enabled) }
                } else { Text("Local Whisper requires Apple Silicon.") }
            }
        }
        .task { await model.refresh() }
        .onChange(of: configuration.localOnly) { Task { await model.refreshOllama() } }
        .confirmationDialog("Download Whisper model?", isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }), presenting: pendingDownload) { item in
            Button("Download \(item.title)") { model.download(item); pendingDownload = nil }
        } message: { item in
            Text("Downloads \(ByteCountFormatter.string(fromByteCount: item.downloadBytes, countStyle: .file)) of model data from trusted repositories. No recording content is sent.")
        }
        .confirmationDialog("Remove downloaded model?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), presenting: pendingRemoval) { item in
            Button("Remove \(item.title)", role: .destructive) { Task { await model.remove(item) }; pendingRemoval = nil }
        } message: { _ in Text("Recordings, transcripts, summaries and chat history are preserved.") }
    }
}

struct OllamaModelPicker: View {
    let title: String
    @Binding var selection: String
    @Bindable var configuration: LocalAIConfiguration
    var body: some View {
        VStack(alignment: .leading) {
            Picker(title, selection: $selection) {
                Text("Choose a model").tag("")
                if !selection.isEmpty && !configuration.models.contains(where: { $0.id == selection }) {
                    Text(selection + " · Model not installed / not verified").tag(selection)
                }
                ForEach(configuration.models) { Text($0.id + ($0.vision ? " · Vision" : " · Text / OCR")).tag($0.id) }
            }
            if !selection.isEmpty && !configuration.models.contains(where: { $0.id == selection }) {
                Text("Model not installed or not verified. Refresh models; AudioNotes will not switch models automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct LocalGenerationSettingsControls: View {
    @Binding var settings: LLMGenerationSettings
    var body: some View {
        DisclosureGroup("Advanced generation settings") {
            TextField("Output safety ceiling (tokens)", value: Binding(
                get: { settings.maxOutputTokens ?? 2048 }, set: { settings.maxOutputTokens = max(1, $0) }), format: .number)
            Text("Ollama reserves at most one quarter of the selected context for output. Desired response length remains a separate instruction.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Temperature", value: String(format: "%.2f", settings.temperature ?? 0.7))
            Slider(value: Binding(get: { settings.temperature ?? 0.7 }, set: { settings.temperature = $0 }), in: 0...2, step: 0.05)
            LabeledContent("Top P", value: String(format: "%.2f", settings.topP ?? 1))
            Slider(value: Binding(get: { settings.topP ?? 1 }, set: { settings.topP = $0 }), in: 0...1, step: 0.05)
        }
    }
}
