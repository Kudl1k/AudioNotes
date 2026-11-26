#if os(macOS)
import SwiftUI

struct ProviderSettingsView: View {
    @Bindable var transcriptionConfig: TranscriptionConfiguration
    @Bindable var llmConfig: LLMConfiguration
    @State private var localAISettings: LocalAISettingsViewModel
    @StateObject private var model: ProviderSettingsViewModel

    @ObservedObject private var updates: UpdateService
    @State private var information: ReleaseInformationView.Page?

    @State private var selectedPage: SettingsPage? = .defaults(.transcription)
    @Environment(\.libraryStorage) private var libraryStorage
    private let navigation: SettingsNavigation?

    private enum SettingsPage: Hashable, Identifiable {
        case defaults(GenerationDefaultsView.Feature)
        case presets, privacy, usage, about, driveSharing
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
            case .defaults(let feature): feature.title
            case .privacy: "Privacy & Data"
            case .driveSharing: "Google Drive Sharing"
            case .usage: "Usage & Costs"
            case .about: "Help & About"
            case .presets: "Presets"
            case .provider(let provider): provider.rawValue
            }
        }

        var icon: String {
            switch self {
            case .defaults(.transcription): "waveform"
            case .defaults(.summary): "doc.text"
            case .defaults(.chat): "bubble.left.and.bubble.right"
            case .privacy: "hand.raised"
            case .driveSharing: "folder.badge.person.crop"
            case .usage: "dollarsign.circle"
            case .about: "info.circle"
            case .presets: "slider.horizontal.3"
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
        updates: UpdateService = UpdateService(enabled: false),
        navigation: SettingsNavigation? = nil
    ) {
        _localAISettings = State(initialValue: localAISettings ?? LocalAISettingsViewModel(
            configuration: llmConfig.localAI, store: whisperStore
        ))
        self.updates = updates
        self.navigation = navigation
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
        NavigationSplitView {
            List(selection: $selectedPage) {
                Section("AI Defaults") {
                    ForEach(GenerationDefaultsView.Feature.allCases.map(SettingsPage.defaults) + [.presets]) { page in
                        sidebarLabel(for: page).tag(page)
                    }
                }

                Section("Connections & Models") {
                    ForEach(ProviderConnectionsView.ConnectionProvider.allCases) { provider in
                        let page = SettingsPage.provider(provider)
                        sidebarLabel(for: page).tag(page)
                    }
                }

                Section("Soniquill") {
                    ForEach([SettingsPage.privacy, .driveSharing, .usage, .about]) { page in
                        sidebarLabel(for: page).tag(page)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 250)
        } detail: {
            settingsDetail
                .navigationTitle((selectedPage ?? .defaults(.transcription)).title)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 520)
        .task { await model.refresh() }
        .task { await localAISettings.refreshInstalled() }
        .environment(\.openSettingsAction, OpenSettingsAction { section in
            if let section { select(section) }
        })
        .onChange(of: navigation?.request, initial: true) {
            if let request = navigation?.request { select(request.section) }
        }
        .sheet(item: $information) { ReleaseInformationView(page: $0) }
    }

    private func select(_ section: SettingsSection) {
        switch section {
        case .transcription: selectedPage = .defaults(.transcription)
        case .summary: selectedPage = .defaults(.summary)
        case .chat: selectedPage = .defaults(.chat)
        case .presets: selectedPage = .presets
        case .openAI: selectedPage = .provider(.openAI)
        case .gemini: selectedPage = .provider(.gemini)
        case .localAI: selectedPage = .provider(.local)
        case .usage: selectedPage = .usage
        case .privacy: selectedPage = .privacy
        }
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
        switch selectedPage ?? .defaults(.transcription) {
        case .defaults(let feature):
            Form {
                GenerationDefaultsView(feature: feature, localAISettings: localAISettings, transcriptionConfig: transcriptionConfig, llmConfig: llmConfig, model: model)
            }
            .formStyle(.grouped)
            .id(feature)
        case .privacy:
            privacyPage
        case .driveSharing:
            DriveProjectsSheet(storage: libraryStorage, isEmbedded: true)
        case .usage:
            UsageCostView(isEmbedded: true)
        case .about:
            aboutPage
        case .presets:
            PresetsManagementView()
        case .provider(let provider):
            ProviderConnectionsView(
                llmConfig: llmConfig,
                model: model,
                localAISettings: localAISettings,
                selectedProvider: provider
            )
        }
    }

    private var privacyPage: some View {
        Form {
            Section {
                Toggle("Local Only", isOn: Binding(
                    get: { llmConfig.localAI.localOnly },
                    set: { llmConfig.localAI.localOnly = $0 }
                ))
                OpenSettingsLink(section: .localAI) { Text("Manage Local Models…") }
            } header: {
                Text("AI Privacy")
            } footer: {
                Text("Local Only blocks cloud providers, remote servers, and cloud-backed Ollama models.")
            }

            Section {
                if PlatformCapabilities.current.supportsFinderReveal {
                    Button("Reveal Data Folder") { Workspace.open(AppStorageLocations.applicationSupport()) }
                }
                Button("Privacy Policy") { information = .privacy }
            } header: {
                Text("Data")
            } footer: {
                Text("See Soniquill Help for backup instructions. Export Diagnostics is available from the Help menu.")
            }
        }
        .formStyle(.grouped)
    }

    private var aboutPage: some View {
        Form {
            Section("Help") {
                Button { information = .help } label: {
                    Label("Soniquill Help", systemImage: "questionmark.circle")
                }
                Button { information = .licenses } label: {
                    Label("Third-Party Licenses", systemImage: "doc.plaintext")
                }
            }
            Section("About Soniquill") {
                LabeledContent("Version & Build", value: "\(ReleaseIdentity().version) (\(ReleaseIdentity().build))")
            }
            if PlatformCapabilities.current.supportsSparkleUpdates {
                Section {
                    Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                        .disabled(!updates.isConfigured)
                    Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
                } header: {
                    Text("Updates")
                } footer: {
                    if !updates.isConfigured {
                        Text("Updates are unavailable in this build.")
                    }
                }
            }
#if DEBUG
            Section("Development") {
                Button(model.copiedLogsNotice ? "Copied Debug Logs" : "Copy Debug Logs") { model.copyLogs() }
            }
#endif
        }
        .formStyle(.grouped)
    }

}

@Observable @MainActor
final class SettingsNavigation {
    struct Request: Equatable {
        let section: SettingsSection
        let id = UUID()
    }

    var request: Request?
}
#endif
