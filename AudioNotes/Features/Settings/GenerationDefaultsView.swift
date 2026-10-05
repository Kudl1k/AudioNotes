import SwiftUI

struct GenerationDefaultsView: View {
    @Bindable var transcriptionConfig: TranscriptionConfiguration
    @Bindable var llmConfig: LLMConfiguration
    @ObservedObject var model: ProviderSettingsViewModel
    @State private var showAdvancedSummary = false
    @State private var showAdvancedChat = false

    var body: some View {
        Group {
            transcriptionSection
            summarySection
            chatSection
        }
    }

    private var transcriptionSection: some View {
        Section("Transcription") {
            Picker("Provider", selection: $transcriptionConfig.selectedProvider) {
                ForEach(TranscriptionProviderID.selectable) { Text($0.title).tag($0) }
            }
            if transcriptionConfig.selectedProvider == .mock {
                Text("Mock provides deterministic local results for testing without an API key.")
                    .foregroundStyle(.secondary)
            } else if transcriptionConfig.selectedProvider == .localWhisper {
                Text("Runs on this Mac · No API charge").foregroundStyle(.secondary)
                if LocalAISettingsViewModel.supportsWhisper {
                    Picker("Model", selection: Binding(
                        get: { llmConfig.localAI.whisperModel },
                        set: { llmConfig.localAI.whisperModel = $0 }
                    )) {
                        ForEach(WhisperModelDescriptor.bundled) { Text($0.title).tag($0.id) }
                    }
                    Picker("Language", selection: Binding(
                        get: { llmConfig.localAI.whisperLanguage },
                        set: { llmConfig.localAI.whisperLanguage = $0 }
                    )) {
                        Text("Auto Detect").tag("")
                        ForEach(LocalAISettingsViewModel.languages, id: \.self) {
                            Text(Locale.current.localizedString(forLanguageCode: $0) ?? $0).tag($0)
                        }
                    }
                } else {
                    Text("Local Whisper requires Apple Silicon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Download and manage Whisper models in Providers → Local AI.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if transcriptionConfig.selectedProvider == .gemini {
                Picker("Model", selection: $transcriptionConfig.geminiModel) {
                    Text("Gemini 3.5 Transcribe").tag("gemini-3.5-transcribe")
                }
                Text("Word timestamps and speaker labels · up to 30 minutes · billed to the configured Google Cloud project.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: $transcriptionConfig.openAIModel) {
                    ForEach(model.availableTranscriptionModels) { item in
                        Text(item.title).tag(item)
                    }
                }
                HStack {
                    if model.isFetchingTranscriptionModels {
                        ProgressView().controlSize(.small)
                        Text("Fetching voice models…")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.keyIsConfigured {
                        Button("Refresh Voice Models") {
                            Task { await model.fetchVoiceModels() }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                if let err = model.transcriptionModelsError {
                    InlineErrorLabel(err)
                }
                Text("Whisper-1 supplies segment timestamps for playback seeking. Runs in OpenAI's cloud.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Language", selection: $transcriptionConfig.language) {
                    ForEach(TranscriptionLanguage.allCases) { Text($0.title).tag($0) }
                }
                Text("Manage your OpenAI API key in Providers. Transcription is billed per minute; larger recordings are split automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summarySection: some View {
        Section("Summaries") {
            Picker("Provider", selection: $llmConfig.selectedProvider) {
                ForEach(LLMProviderID.selectable) { Text($0.title).tag($0) }
            }
            if llmConfig.selectedProvider == .mock {
                Text("Mock generates structured summaries locally without an API key or network access.")
                    .foregroundStyle(.secondary)
            } else if llmConfig.selectedProvider == .openAI {
                Picker("Authentication", selection: $llmConfig.openAIAuthMethod) {
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
                Text("Manage the Ollama connection and installed models in Providers → Local AI.").font(.caption).foregroundStyle(.secondary)
            } else if llmConfig.selectedProvider == .llamaCpp {
                TextField("Loaded model name", text: Binding(
                    get: { llmConfig.localAI.llamaCppModel },
                    set: { llmConfig.localAI.llamaCppModel = $0 }
                ))
                Text("Configure the llama.cpp server address in Providers → Local AI.").font(.caption).foregroundStyle(.secondary)
            } else if llmConfig.selectedProvider == .gemini {
                Picker("Authentication", selection: $llmConfig.summaryGeminiAuthenticationMethod) {
                    Text("Google Account").tag(ProviderAuthenticationMethod.oauth)
                    Text("API Key").tag(ProviderAuthenticationMethod.apiKey)
                }
                Picker("Model", selection: $llmConfig.summaryGeminiModel) {
                    Text("Gemini 3.8 Flash").tag("gemini-3.8-flash")
                }
                Text("Gemini Developer API use is billed to the configured Google Cloud project. Gemini Advanced does not pay API charges.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("Detail Level", selection: $llmConfig.summaryOutputLength) {
                ForEach(OutputLength.allCases) { Text($0.title).tag($0) }
            }

            DisclosureGroup(isExpanded: $showAdvancedSummary) {
                VStack(alignment: .leading, spacing: 10) {
                    if llmConfig.summaryCapabilities.supportsMaxOutputTokens {
                        TextField("Max output tokens", value: Binding(
                            get: { llmConfig.summarySettings.maxOutputTokens ?? 4000 },
                            set: { value in var settings = llmConfig.summarySettings; settings.maxOutputTokens = max(1, value); llmConfig.summarySettings = settings }
                        ), format: .number)
                    }
                    if llmConfig.summaryCapabilities.supportsTemperature {
                        HStack {
                            Text("Temperature:")
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
            } label: {
                Text("Advanced Summary Settings")
                    .font(.subheadline)
            }
        }
    }

    private var chatSection: some View {
        Section("Chat") {
            Picker("Provider", selection: $llmConfig.chatProvider) {
                ForEach(LLMProviderID.selectable) { Text($0.title).tag($0) }
            }
            if llmConfig.chatProvider == .openAI {
                Picker("Authentication", selection: $llmConfig.chatAuthMethod) {
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

            Picker("Response length", selection: $llmConfig.chatOutputLength) {
                ForEach(OutputLength.allCases) { Text($0.title).tag($0) }
            }
            DisclosureGroup(isExpanded: $showAdvancedChat) {
                VStack(alignment: .leading, spacing: 10) {
                    if llmConfig.chatCapabilities.supportsMaxOutputTokens {
                        TextField("Max output tokens", value: Binding(
                            get: { llmConfig.chatSettings.maxOutputTokens ?? 6000 },
                            set: { value in var settings = llmConfig.chatSettings; settings.maxOutputTokens = max(1, value); llmConfig.chatSettings = settings }
                        ), format: .number)
                    }
                    if llmConfig.chatCapabilities.supportsTemperature {
                        HStack {
                            Text("Temperature:")
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
            } label: {
                Text("Advanced Chat Settings")
                    .font(.subheadline)
            }
        }
    }
}
