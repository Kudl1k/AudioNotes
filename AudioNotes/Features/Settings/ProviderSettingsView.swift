import SwiftUI

struct ProviderSettingsView: View {
    @Bindable var transcriptionConfig: TranscriptionConfiguration
    @Bindable var llmConfig: LLMConfiguration
    @State private var localAISettings: LocalAISettingsViewModel
    @StateObject private var model: ProviderSettingsViewModel

    @ObservedObject private var updates: UpdateService
    @State private var information: ReleaseInformationView.Page?

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
        localAISettings: LocalAISettingsViewModel? = nil,
        updates: UpdateService = UpdateService(enabled: false)
    ) {
        _localAISettings = State(initialValue: localAISettings ?? LocalAISettingsViewModel(
            configuration: llmConfig.localAI, store: whisperStore
        ))
        self.updates = updates
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
        .sheet(item: $information) { ReleaseInformationView(page: $0) }
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

            if PlatformCapabilities.current.supportsSparkleUpdates {
                Section("Updates") {
                    Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                        .disabled(!updates.isConfigured)
                    Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
                    if !updates.isConfigured {
                        Text("Updates are unavailable in this build. Release hosting and signing must be configured by the publisher.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Storage & Privacy") {
                if PlatformCapabilities.current.supportsFinderReveal {
                    Button("Reveal Data Folder") { Workspace.open(AppStorageLocations.applicationSupport()) }
                }
                Button("Privacy") { information = .privacy }
                Button("AudioNotes Help") { information = .help }
                Button("Third-Party Licenses") { information = .licenses }
                Text("Use Help → Export Diagnostics for a report that excludes your content and credentials. To make a full backup, quit AudioNotes and copy the data folders described in Help.")
                    .font(.caption).foregroundStyle(.secondary)
            }
#if DEBUG
            Section("Development") {
                Button("Copy Debug Logs") { model.copyLogs() }
            }
#endif

            Section("About AudioNotes") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AudioNotes \(ReleaseIdentity().version) (\(ReleaseIdentity().build))")
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
                        .foregroundStyle(.blue).accessibilityHidden(true)
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
                        .foregroundStyle(.red).accessibilityHidden(true)
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
