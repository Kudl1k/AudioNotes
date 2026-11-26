import SwiftUI

private extension View {
    @ViewBuilder
    func flexibleMenuControlWidth() -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            self
                .buttonSizing(.flexible)
                .frame(minWidth: 0, maxWidth: .infinity)
        } else {
            self.frame(minWidth: 0, maxWidth: .infinity)
        }
    }
}

struct GenerationProviderControls<Provider: Hashable & Identifiable>: View {
    let providers: [Provider]
    let title: (Provider) -> String
    @Binding var selectedProvider: Provider?
    @Binding var selectedModel: String?
    let models: [GenerationModelOption]
    let providerName: String
    let modelName: String?

    private var defaultTitle: String {
#if os(iOS)
        "Defaults"
#else
        "Use default / preset"
#endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Provider").font(.caption).foregroundStyle(.secondary)
            Picker("Provider", selection: $selectedProvider) {
                Text(defaultTitle).tag(Optional<Provider>.none)
                ForEach(providers) { provider in
                    Text(title(provider)).tag(Optional(provider))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .flexibleMenuControlWidth()

            if !models.isEmpty || modelName != nil {
                Text("Model").font(.caption).foregroundStyle(.secondary)
                Picker("Model", selection: $selectedModel) {
                    Text(defaultTitle).tag(Optional<String>.none)
                    if let selectedModel, !models.contains(where: { $0.id == selectedModel }) {
                        Text(selectedModel).tag(Optional(selectedModel))
                    }
                    ForEach(models) { model in
                        Text(model.title).tag(Optional(model.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .flexibleMenuControlWidth()
            }
            Text(summaryText)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(summaryText)
        }
    }

    private var summaryText: String {
        if let modelName, !providerName.localizedStandardContains(modelName) {
            return "\(providerName) · \(modelName)"
        }
        return providerName
    }
}

#if os(macOS)
struct TranscriptionOptionsButton: View {
    let model: RecordingViewModel
    @State private var showsOptions = false

    var body: some View {
        Button("Transcription Options…") { showsOptions = true }
            .accessibilityIdentifier("transcription.options")
            .popover(isPresented: $showsOptions) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcription Options").font(.headline)
                    TranscriptionOptionsForm(model: model)
                    HStack {
                        OpenSettingsLink(section: .transcription) { Text("Transcription Settings…") }
                        Spacer()
                        Button("Done") { showsOptions = false }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .frame(width: 420)
            }
    }
}

struct TranscriptionOptionsForm: View {
    @Bindable var model: RecordingViewModel
    var showsEstimatedCost = true

    var body: some View {
        Form {
            LabeledContent("Provider") {
                Picker("Provider", selection: $model.selectedProvider) {
                    Text("Use App Setting").tag(Optional<TranscriptionProviderID>.none)
                    ForEach(TranscriptionProviderID.currentPlatformSelectable) { provider in
                        Text(provider.title).tag(Optional(provider))
                    }
                }
                .labelsHidden()
                .flexibleMenuControlWidth()
            }
            if !model.availableModels.isEmpty || model.selectedModel != nil {
                LabeledContent("Model") {
                    Picker("Model", selection: $model.selectedModel) {
                        Text("Automatic").tag(Optional<String>.none)
                        if let selectedModel = model.selectedModel,
                           !model.availableModels.contains(where: { $0.id == selectedModel }) {
                            Text(selectedModel).tag(Optional(selectedModel))
                        }
                        ForEach(model.availableModels) { option in
                            Text(option.title).tag(Optional(option.id))
                        }
                    }
                    .labelsHidden()
                    .flexibleMenuControlWidth()
                }
            }
            LabeledContent("Uses") {
                Text(model.transcriptionConfiguration)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.transcriptionConfiguration)
            }
            if showsEstimatedCost {
                LabeledContent("Estimated Cost") {
                    Text(model.transcriptionEstimate.displayText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(model.transcriptionEstimate.displayText)
                }
            }
        }
        .formStyle(.columns)
        .pickerStyle(.menu)
        .disabled(model.state.isProcessing)
    }
}
#endif

struct SummaryProviderControls: View {
    @Bindable var model: SummaryViewModel

    private var summaryProviders: [LLMProviderID] {
#if os(iOS)
        LLMProviderID.currentPlatformSelectable
#else
        LLMProviderID.currentPlatformSelectable.filter { $0 != .gemini }
#endif
    }

    var body: some View {
        GenerationProviderControls(providers: summaryProviders, title: { $0.title },
            selectedProvider: $model.selectedProvider, selectedModel: $model.selectedModel,
            models: model.availableModels, providerName: model.providerName, modelName: model.selectedModelName)
            .disabled(model.state.isGenerating)
    }
}
