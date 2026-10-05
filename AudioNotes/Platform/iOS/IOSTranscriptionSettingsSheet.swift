#if os(iOS)
import SwiftUI

/// Availability is refreshed once on presentation, never discovered from a view body.
struct IOSTranscriptionSettingsSheet: View {
    @Bindable var model: RecordingViewModel
    let services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var providers: [TranscriptionProviderID] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    if loading { ProgressView("Checking available providers…") }
                    ForEach(providers) { provider in
                        Button {
                            model.selectedProvider = provider
                        } label: {
                            HStack {
                                Text(provider.title).foregroundStyle(.primary)
                                Spacer()
                                if provider == (model.selectedProvider ?? services.configuration.selectedProvider) { Image(systemName: "checkmark") }
                            }
                        }.accessibilityIdentifier("transcription.provider.\(provider.rawValue)")
                    }
                    if !loading && providers.isEmpty {
                        Text("Connect a transcription account in Settings.").foregroundStyle(.secondary)
                        OpenSettingsLink { Text("Open Settings") }
                    }
                }
                if !model.availableModels.isEmpty {
                    Section("Model") {
                        Picker("Model", selection: Binding(get: { model.selectedModel ?? model.availableModels.first(where: { $0.title == model.selectedModelName })?.id ?? defaultModel }, set: { model.selectedModel = $0 })) {
                            ForEach(model.availableModels) { Text($0.title).tag($0.id) }
                        }
                        .accessibilityIdentifier("transcription.model")
                    }
                }
                if (model.selectedProvider ?? services.configuration.selectedProvider) == .localWhisper {
                    Section("On-device Model") {
                        if let descriptor = services.localAISettings.models.first(where: { $0.id == (model.selectedModel ?? services.llmConfiguration.localAI.whisperModel) }) {
                            IOSWhisperModelRow(model: descriptor, settings: services.localAISettings)
                        }
                        Text("No audio upload. Timestamps and language detection are supported. Speaker diarization is unavailable.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if [.openAI, .localWhisper].contains(model.selectedProvider ?? services.configuration.selectedProvider) {
                    Section("Options") {
                        Picker("Language", selection: Binding(get: { model.selectedLanguage ?? ((model.selectedProvider ?? services.configuration.selectedProvider) == .localWhisper ? (TranscriptionLanguage(rawValue: services.llmConfiguration.localAI.whisperLanguage) ?? .automatic) : services.configuration.language) }, set: { model.selectedLanguage = $0 })) {
                            ForEach(TranscriptionLanguage.allCases) { Text($0.title).tag($0) }
                        }.accessibilityIdentifier("transcription.language")
                    }
                }
                Section {
                    Button("Reset to Defaults", action: model.resetTranscriptionOverrides)
                        .disabled(!model.hasTranscriptionOverrides)
                        .accessibilityIdentifier("transcription.reset")
                } footer: {
                    Text((model.hasTranscriptionOverrides ? "Custom settings. " : "Using AI Defaults. ") + "Changes apply to this recording. Provider capabilities follow AI Defaults. Speaker labels are supplied when supported by the selected provider.")
                }
            }
            .disabled(model.state.isProcessing)
            .navigationTitle("Transcription Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--performance-fixtures") {
                    providers = ProcessInfo.processInfo.arguments.contains("--ios-local-ai-review") ? [.localWhisper] : [.mock]; loading = false; return
                }
#endif
                let key = (try? await services.credentials.containsKey(for: .openAI)) == true
                let google = await services.googleGeminiOAuth.account() != nil
                providers = IOSProviderAvailability.transcription(openAIKey: key, geminiConnected: google,
                    includeMock: model.isMockProvider, localWhisperSupported: LocalAISettingsViewModel.supportsWhisper)
                await services.localAISettings.refreshInstalled()
                loading = false
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private var defaultModel: String {
        if (model.selectedProvider ?? services.configuration.selectedProvider) == .localWhisper { return services.llmConfiguration.localAI.whisperModel }
        return (model.selectedProvider ?? services.configuration.selectedProvider) == .gemini ? services.configuration.geminiModel : services.configuration.openAIModel.rawValue
    }
}
#endif
