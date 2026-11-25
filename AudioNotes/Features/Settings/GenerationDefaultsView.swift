import SwiftUI

struct GenerationDefaultsView: View {
    enum Feature: CaseIterable {
        case transcription, summary, chat

        var title: String {
            switch self {
            case .transcription: "Transcription"
            case .summary: "Summaries"
            case .chat: "Chat"
            }
        }
    }

    let feature: Feature
    let localAISettings: LocalAISettingsViewModel
    @Bindable var transcriptionConfig: TranscriptionConfiguration
    @Bindable var llmConfig: LLMConfiguration
    @ObservedObject var model: ProviderSettingsViewModel
    @State private var showAdvancedSummary = false
    @State private var showAdvancedChat = false

    var body: some View {
        switch feature {
        case .transcription: transcriptionSection
        case .summary: summarySection
        case .chat: chatSection
        }
    }

    @ViewBuilder
    private var transcriptionSection: some View {
        Section {
            Picker("Provider", selection: $transcriptionConfig.selectedProvider) {
                ForEach(TranscriptionProviderID.selectable) { Text($0.title).tag($0) }
            }

            switch transcriptionConfig.selectedProvider {
            case .mock:
                EmptyView()
            case .localWhisper:
                if LocalAISettingsViewModel.supportsWhisper {
                    Picker("Model", selection: Binding(get: { llmConfig.localAI.whisperModel }, set: { llmConfig.localAI.whisperModel = $0 })) {
                        ForEach(WhisperModelDescriptor.bundled) { Text($0.title).tag($0.id) }
                    }
                    if !localAISettings.installed.contains(llmConfig.localAI.whisperModel) {
                        OpenSettingsLink(section: .localAI) { Text("Manage Whisper Models…") }
                    }
                } else {
                    Text("Local Whisper requires Apple Silicon.").foregroundStyle(.secondary)
                }
            case .openAI:
                Picker("Model", selection: $transcriptionConfig.openAIModel) {
                    ForEach(model.availableTranscriptionModels) { Text($0.title).tag($0) }
                }
                if model.isFetchingTranscriptionModels {
                    ProgressView("Fetching voice models…").controlSize(.small)
                } else if model.keyIsConfigured {
                    Button("Refresh Voice Models") { Task { await model.fetchVoiceModels() } }
                } else {
                    OpenSettingsLink(section: .openAI) { Text("Set Up OpenAI API Key…") }
                }
                if let error = model.transcriptionModelsError { InlineErrorLabel(error) }
            }
        } header: {
            Text("Transcription Service")
        } footer: {
            Text(transcriptionModelNote)
        }

        if transcriptionConfig.selectedProvider == .openAI {
            Section("Audio") {
                Picker("Language", selection: $transcriptionConfig.language) {
                    ForEach(TranscriptionLanguage.allCases) { Text($0.title).tag($0) }
                }
            }
        } else if transcriptionConfig.selectedProvider == .localWhisper, LocalAISettingsViewModel.supportsWhisper {
            Section("Audio") {
                Picker("Language", selection: Binding(get: { llmConfig.localAI.whisperLanguage }, set: { llmConfig.localAI.whisperLanguage = $0 })) {
                    Text("Auto Detect").tag("")
                    ForEach(LocalAISettingsViewModel.languages, id: \.self) {
                        Text(Locale.current.localizedString(forLanguageCode: $0) ?? $0).tag($0)
                    }
                }
            }
        }
    }

    private var transcriptionModelNote: String {
        switch transcriptionConfig.selectedProvider {
        case .mock: "Generates sample transcripts locally for development."
        case .localWhisper: "Processes audio on this Mac and provides segment timestamps."
        case .openAI:
            transcriptionConfig.openAIModel.supportsSegmentTimestamps
                ? "Provides segment timestamps for playback. Audio is sent to OpenAI for API billing."
                : "Returns transcript text. Audio is sent to OpenAI for API billing."
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section("Model") {
            Picker("Provider", selection: $llmConfig.selectedProvider) {
                ForEach(LLMProviderID.selectable) { Text($0.title).tag($0) }
            }
            if llmConfig.selectedProvider == .mock {
                Text("Mock generates structured summaries locally without an API key or network access.")
                    .foregroundStyle(.secondary)
            } else if llmConfig.selectedProvider == .openAI {
                Picker("Connection", selection: $llmConfig.openAIAuthMethod) {
                    ForEach(OpenAIAuthenticationMethod.allCases) { Text($0.title).tag($0) }
                }

                if llmConfig.openAIAuthMethod == .apiKey {
                    Picker("Model", selection: $llmConfig.openAIModel) {
                        ForEach(OpenAILLMModel.allCases) { Text($0.title).tag($0) }
                    }
                } else {
                    Picker("Model", selection: $llmConfig.chatGPTModel) {
                        ForEach(model.availableChatGPTModels) { item in
                            Text(item.displayName).tag(item.slug)
                        }
                    }
                    HStack {
                        if model.isFetchingChatGPTModels {
                            ProgressView().controlSize(.small)
                            Text("Fetching ChatGPT models…")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if model.isChatGPTSignedIn {
                            Button("Refresh ChatGPT Models") {
                                Task { await model.fetchChatGPTModels() }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                    if let err = model.chatGPTModelsError {
                        InlineErrorLabel(err)
                    }
                }

            } else if llmConfig.selectedProvider == .anthropic {
#if os(macOS)
                ClaudeModelPicker(selection: $llmConfig.summaryClaudeModel, configuration: llmConfig, settings: model)
#else
                Text("Claude Code CLI integration is available on macOS.")
                    .font(.caption).foregroundStyle(.secondary)
#endif
            } else if llmConfig.selectedProvider == .ollama {
                OllamaModelPicker(title: "Model", selection: Binding(get: { llmConfig.localAI.summaryModel }, set: { llmConfig.localAI.summaryModel = $0 }), configuration: llmConfig.localAI)
                Text("Manage the Ollama connection and installed models in Connections & Models → Local AI.").font(.caption).foregroundStyle(.secondary)
            } else if llmConfig.selectedProvider == .llamaCpp {
                TextField("Loaded model name", text: Binding(
                    get: { llmConfig.localAI.llamaCppModel },
                    set: { llmConfig.localAI.llamaCppModel = $0 }
                ))
                Text("Configure the llama.cpp server address in Connections & Models → Local AI.").font(.caption).foregroundStyle(.secondary)
            } else if llmConfig.selectedProvider == .gemini {
                Picker("Connection", selection: $llmConfig.summaryGeminiAuthenticationMethod) {
                    Text("Google Account").tag(ProviderAuthenticationMethod.oauth)
                    Text("API Key").tag(ProviderAuthenticationMethod.apiKey)
                }
                Picker("Model", selection: $llmConfig.summaryGeminiModel) {
                    Text("Gemini 3.8 Flash").tag("gemini-3.8-flash")
                }
                Text("Gemini Developer API use is billed to the configured Google Cloud project. Gemini Advanced does not pay API charges.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Section("Output") {
            Picker("Detail Level", selection: $llmConfig.summaryOutputLength) {
                ForEach(OutputLength.allCases) { Text($0.title).tag($0) }
            }
        }

        if llmConfig.summaryCapabilities.supportsMaxOutputTokens || llmConfig.summaryCapabilities.supportsTemperature {
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvancedSummary) {
                    VStack(alignment: .leading, spacing: 10) {
                        if llmConfig.summaryCapabilities.supportsMaxOutputTokens {
                            TextField("Max output tokens", value: Binding(
                                get: { llmConfig.summarySettings.maxOutputTokens ?? 4000 },
                                set: { value in var settings = llmConfig.summarySettings; settings.maxOutputTokens = max(1, value); llmConfig.summarySettings = settings }
                            ), format: .number)
                        }
                        if llmConfig.summaryCapabilities.supportsTemperature {
                            HStack {
                                Text("Temperature")
                                Spacer()
                                Text(String(format: "%.2f", llmConfig.summarySettings.temperature ?? 0.3))
                                    .monospacedDigit()
                            }
                            Slider(
                                value: Binding(
                                    get: { llmConfig.summarySettings.temperature ?? 0.3 },
                                    set: { val in
                                        var current = llmConfig.summarySettings
                                        current.temperature = val
                                        llmConfig.summarySettings = current
                                    }
                                ),
                                in: 0.0...2.0,
                                step: 0.05
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var chatSection: some View {
        Section("Model") {
            Picker("Provider", selection: $llmConfig.chatProvider) {
                ForEach(LLMProviderID.selectable) { Text($0.title).tag($0) }
            }
            if llmConfig.chatProvider == .openAI {
                Picker("Connection", selection: $llmConfig.chatAuthMethod) {
                    ForEach(OpenAIAuthenticationMethod.allCases) { Text($0.title).tag($0) }
                }

                if llmConfig.chatAuthMethod == .apiKey {
                    Picker("Model", selection: $llmConfig.chatOpenAIModel) {
                        ForEach(OpenAILLMModel.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Chat is billed per token by OpenAI. Responses use reasoning where supported.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $llmConfig.chatChatGPTModel) {
                        ForEach(model.availableChatGPTModels) { item in
                            Text(item.displayName).tag(item.slug)
                        }
                    }
                    HStack {
                        if model.isFetchingChatGPTModels {
                            ProgressView().controlSize(.small)
                            Text("Fetching ChatGPT models…")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if model.isChatGPTSignedIn {
                            Button("Refresh ChatGPT Models") {
                                Task { await model.fetchChatGPTModels() }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                    if let error = model.chatGPTModelsError {
                        InlineErrorLabel(error)
                    }
                    Text("Chat uses your ChatGPT account. It will not fall back to API-key billing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if llmConfig.chatProvider == .anthropic {
#if os(macOS)
                ClaudeModelPicker(selection: $llmConfig.chatClaudeModel, configuration: llmConfig, settings: model)
#else
                Text("Claude Code CLI integration is available on macOS.")
                    .font(.caption).foregroundStyle(.secondary)
#endif
            } else if llmConfig.chatProvider == .ollama {
                OllamaModelPicker(title: "Model", selection: Binding(get: { llmConfig.localAI.chatModel }, set: { llmConfig.localAI.chatModel = $0 }), configuration: llmConfig.localAI)
            } else if llmConfig.chatProvider == .llamaCpp {
                TextField("Loaded model name", text: Binding(
                    get: { llmConfig.localAI.llamaCppModel },
                    set: { llmConfig.localAI.llamaCppModel = $0 }
                ))
            } else if llmConfig.chatProvider == .mock {
                Text("Mock simulates streaming answers and transcript citations locally without an API key or network access.")
                    .foregroundStyle(.secondary)
            } else if llmConfig.chatProvider == .gemini {
                Picker("Model", selection: $llmConfig.chatGeminiModel) {
                    Text("Gemini 3.8 Flash").tag("gemini-3.8-flash")
                }
                Text("Gemini Developer API use is billed to the configured Google Cloud project. Gemini Advanced does not pay API charges.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Claude chat is not available in this build yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Section("Output") {
            Picker("Response length", selection: $llmConfig.chatOutputLength) {
                ForEach(OutputLength.allCases) { Text($0.title).tag($0) }
            }
        }

        if llmConfig.chatCapabilities.supportsMaxOutputTokens || llmConfig.chatCapabilities.supportsTemperature {
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvancedChat) {
                    VStack(alignment: .leading, spacing: 10) {
                        if llmConfig.chatCapabilities.supportsMaxOutputTokens {
                            TextField("Max output tokens", value: Binding(
                                get: { llmConfig.chatSettings.maxOutputTokens ?? 6000 },
                                set: { value in var settings = llmConfig.chatSettings; settings.maxOutputTokens = max(1, value); llmConfig.chatSettings = settings }
                            ), format: .number)
                        }
                        if llmConfig.chatCapabilities.supportsTemperature {
                            HStack {
                                Text("Temperature")
                                Spacer()
                                Text(String(format: "%.2f", llmConfig.chatSettings.temperature ?? 0.7))
                                    .monospacedDigit()
                            }
                            Slider(
                                value: Binding(
                                    get: { llmConfig.chatSettings.temperature ?? 0.7 },
                                    set: { val in
                                        var current = llmConfig.chatSettings
                                        current.temperature = val
                                        llmConfig.chatSettings = current
                                    }
                                ),
                                in: 0.0...2.0,
                                step: 0.05
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
