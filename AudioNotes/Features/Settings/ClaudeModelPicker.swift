import SwiftUI

struct ClaudeModelPicker: View {
    @Binding var selection: String
    @Bindable var configuration: LLMConfiguration
    @ObservedObject var settings: ProviderSettingsViewModel

    private var options: [ClaudeCLIModel] {
        ClaudeCLIModel.options(configuration.cachedClaudeModels, preserving: selection)
    }

    var body: some View {
        Picker("Model", selection: $selection) {
            ForEach(options) { model in
                Text(model.displayName).tag(model.id)
            }
        }
        if let description = options.first(where: { $0.id == selection })?.description {
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            if settings.isFetchingClaudeModels {
                ProgressView().controlSize(.small)
                Text("Fetching Claude models…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Refresh Claude Models") { Task { await settings.fetchClaudeModels() } }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        if let error = settings.claudeModelsError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        Text("Uses your Claude Code account. Manage the connection in Providers → Anthropic.")
            .font(.caption).foregroundStyle(.secondary)
            .task(id: configuration.claudeExecutablePath) { await settings.loadClaudeModelsIfNeeded() }
    }
}
