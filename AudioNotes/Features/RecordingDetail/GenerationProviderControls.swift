import SwiftUI

struct GenerationProviderControls<Provider: Hashable & Identifiable>: View {
    let providers: [Provider]
    let title: (Provider) -> String
    @Binding var selectedProvider: Provider?
    @Binding var selectedModel: String?
    let models: [GenerationModelOption]
    let providerName: String
    let modelName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider").font(.caption).foregroundStyle(.secondary)
            Picker("Provider", selection: $selectedProvider) {
                Text("Use default / preset").tag(Optional<Provider>.none)
                ForEach(providers) { provider in
                    Text(title(provider)).tag(Optional(provider))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 0, maxWidth: .infinity)
            if !models.isEmpty || modelName != nil {
                Text("Model").font(.caption).foregroundStyle(.secondary)
                Picker("Model", selection: $selectedModel) {
                    Text("Use default / preset").tag(Optional<String>.none)
                    if let selectedModel, !models.contains(where: { $0.id == selectedModel }) {
                        Text(selectedModel).tag(Optional(selectedModel))
                    }
                    ForEach(models) { model in
                        Text(model.title).tag(Optional(model.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 0, maxWidth: .infinity)
            }
            Text(providerName + (modelName.map { " · " + $0 } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(providerName + (modelName.map { " · " + $0 } ?? ""))
        }
    }
}

struct TranscriptionProviderControls: View {
    @Bindable var model: RecordingViewModel

    var body: some View {
        GenerationProviderControls(providers: TranscriptionProviderID.currentPlatformSelectable, title: { $0.title },
            selectedProvider: $model.selectedProvider, selectedModel: $model.selectedModel,
            models: model.availableModels, providerName: model.providerName, modelName: model.selectedModelName)
            .disabled(model.state.isProcessing)
    }
}

struct SummaryProviderControls: View {
    @Bindable var model: SummaryViewModel

    var body: some View {
        GenerationProviderControls(providers: LLMProviderID.currentPlatformSelectable.filter { $0 != .gemini }, title: { $0.title },
            selectedProvider: $model.selectedProvider, selectedModel: $model.selectedModel,
            models: model.availableModels, providerName: model.providerName, modelName: model.selectedModelName)
            .disabled(model.state.isGenerating)
    }
}
