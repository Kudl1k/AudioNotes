import SwiftUI

struct ProviderSettingsView: View {
    @Bindable var transcriptionConfig: TranscriptionConfiguration
    @Bindable var llmConfig: LLMConfiguration
    @State private var localAISettings: LocalAISettingsViewModel
    @StateObject private var model: ProviderSettingsViewModel

    @State private var selectedPage: SettingsPage? = .general

    private enum SettingsPage: Hashable, Identifiable {
        case general, presets, export
        case provider(ProviderConnectionsView.ConnectionProvider)

        var id: Self { self }

        var brandImage: String? {
            switch self {
            case .provider(.openAI): "OpenAIProvider"
            case .provider(.anthropic): "AnthropicProvider"
            case .provider(.gemini): "GeminiProvider"
            default: nil
            }
        }

        var title: String {
            switch self {
            case .general: "General"
            case .presets: "Presets"
            case .export: "Export"
            case .provider(let provider): provider.rawValue
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .presets: "slider.horizontal.3"
            case .export: "square.and.arrow.up"
            case .provider(.openAI): "sparkles"
            case .provider(.anthropic): "text.bubble"
            case .provider(.gemini): "star"
            case .provider(.local): "desktopcomputer"
            }
        }
    }

    init(
        transcriptionConfig: TranscriptionConfiguration,
        llmConfig: LLMConfiguration,
        credentials: any CredentialStoring,
        chatGPTAuth: (any ChatGPTAuthenticating)? = nil,
        tokenRefresher: (any ChatGPTTokenRefreshing)? = nil,
        modelsClient: (any OpenAIModelsFetching)? = nil,
        googleOAuth: GoogleGeminiOAuthService? = nil,
        whisperStore: WhisperModelStore = WhisperModelStore(),
        localAISettings: LocalAISettingsViewModel? = nil
    ) {
        _localAISettings = State(initialValue: localAISettings ?? LocalAISettingsViewModel(
            configuration: llmConfig.localAI, store: whisperStore
        ))
        self.transcriptionConfig = transcriptionConfig
        self.llmConfig = llmConfig
        _model = StateObject(wrappedValue: ProviderSettingsViewModel(
            credentials: credentials,
            chatGPTAuth: chatGPTAuth,
            tokenRefresher: tokenRefresher,
            modelsClient: modelsClient ?? OpenAIModelsClient(),
            transcriptionConfig: transcriptionConfig,
            llmConfig: llmConfig,
            googleOAuth: googleOAuth
        ))
    }

    /// Convenience initializer to preserve compatibility with existing tests
    init(configuration: TranscriptionConfiguration, credentials: any CredentialStoring) {
        self.init(
            transcriptionConfig: configuration,
            llmConfig: LLMConfiguration(),
            credentials: credentials
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedPage) {
                Section("Settings") {
                    ForEach([SettingsPage.general, .presets, .export]) { page in
                        sidebarLabel(for: page)
                            .tag(page)
                    }
                }

                Section("Providers") {
                    ForEach(ProviderConnectionsView.ConnectionProvider.allCases) { provider in
                        let page = SettingsPage.provider(provider)
                        sidebarLabel(for: page)
                            .tag(page)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 32)
        .navigationTitle((selectedPage ?? .general).title)
        .toolbarVisibility(.visible, for: .windowToolbar)
        .frame(minWidth: 820, minHeight: 600)
        .task { await model.refresh() }
    }

    private func sidebarLabel(for page: SettingsPage) -> some View {
        Label {
            Text(page.title)
        } icon: {
            if let brandImage = page.brandImage {
                Image(brandImage)
                    .renderingMode(brandImage == "OpenAIProvider" ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
                    .frame(width: 18, height: 18)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: page.icon)
                    .frame(width: 20)
            }
        }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch selectedPage ?? .general {
        case .general:
            generalPage
        case .presets:
            PresetsManagementView()
        case .export:
            exportPage
        case .provider(let provider):
            ProviderConnectionsView(
                llmConfig: llmConfig,
                model: model,
                localAISettings: localAISettings,
                selectedProvider: provider
            )
        }
    }

    // MARK: - General Page

    private var generalPage: some View {
        Form {
            Section("Privacy") {
                Toggle("Local Only", isOn: Binding(
                    get: { llmConfig.localAI.localOnly },
                    set: { llmConfig.localAI.localOnly = $0 }
                ))
                Text("Keep AI source content on this Mac. Cloud providers, remote servers, and cloud-backed Ollama models are blocked. Install local models in Providers before going offline.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            GenerationDefaultsView(transcriptionConfig: transcriptionConfig, llmConfig: llmConfig, model: model)

            Section("Diagnostics & Logs") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Copy recent diagnostic logs for troubleshooting.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            model.copyLogs()
                        } label: {
                            Label(model.copiedLogsNotice ? "Copied!" : "Copy Debug Logs", systemImage: model.copiedLogsNotice ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                }
            }

            Section("About AudioNotes") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AudioNotes for macOS")
                        .font(.headline)
                    Text("Native audio transcription, AI summaries, and interactive transcript chat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .formStyle(.grouped)
        .padding(16)
    }

    // MARK: - Export Page

    private var exportPage: some View {
        Form {
            Section("Export Defaults") {
                Text("Export your transcripts, AI summaries, and chat histories into standalone Markdown or PDF documents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("Markdown (.md)")
                            .font(.headline)
                        Text("Portable GitHub-flavored markdown with clean formatting, timestamps, and optional front-matter.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                HStack {
                    Image(systemName: "doc.richtext")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text("PDF Document (.pdf)")
                            .font(.headline)
                        Text("Native multi-page document with headers, page numbers, and custom typography.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }
}
