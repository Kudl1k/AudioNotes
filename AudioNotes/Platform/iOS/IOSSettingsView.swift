#if os(iOS)
import SwiftUI

struct IOSSettingsView: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss
    @StateObject private var providerSettings: ProviderSettingsViewModel
    @State private var disconnectChatGPT = false
    @State private var disconnectGemini = false
    @State private var showAdvancedSummary = false
    @State private var showAdvancedChat = false
#if DEBUG
    @State private var reviewAccount: ChatGPTAccount?
#endif
    @State private var isLoadingAccounts = true
    @State private var geminiAccount: ProviderAccount?
    @State private var accountError: String?
    @State private var isConnectingAccount = false
    @ObservedObject private var chatGPTAuthService: ChatGPTAuthService

    enum Destination: Hashable {
        case transcription
        case summary
        case chat
        case defaults
        case presets
        case openAI
        case openAIKey
        case gemini
        case localAI
        case usage
        case information(ReleaseInformationView.Page)
        case about
    }

    @State private var path: [Destination]

    init(services: AppServices, initialSection: SettingsSection? = nil) {
        self.services = services
        _chatGPTAuthService = ObservedObject(wrappedValue: services.chatGPTAuthService)
        _providerSettings = StateObject(wrappedValue: ProviderSettingsViewModel(
            credentials: services.credentials,
            chatGPTAuth: services.chatGPTAuthService,
            tokenRefresher: services.chatGPTTokenRefresher,
            modelsClient: services.modelsClient,
            transcriptionConfig: services.configuration,
            llmConfig: services.llmConfiguration,
            googleOAuth: services.googleGeminiOAuth
        ))
        _path = State(initialValue: Self.initialPath(for: initialSection))
    }

    private static func initialPath(for section: SettingsSection?) -> [Destination] {
        guard let section else { return [] }
        switch section {
        case .transcription: return [.transcription]
        case .summary: return [.summary]
        case .chat: return [.chat]
        case .presets: return [.presets]
        case .openAI: return [.openAI]
        case .gemini: return [.gemini]
        case .localAI: return [.localAI]
        case .usage: return [.usage]
        }
    }

    private var presentedChatGPTAccount: ChatGPTAccount? {
#if DEBUG
        if let reviewAccount { return reviewAccount }
#endif
        return chatGPTAuthService.currentAccount
    }
    private var isOfflineReview: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--performance-fixtures")
#else
        false
#endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    Toggle("Local Only", isOn: Binding(
                        get: { services.llmConfiguration.localAI.localOnly },
                        set: { services.llmConfiguration.localAI.localOnly = $0 }
                    ))
                    .accessibilityIdentifier("settings.localOnly")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Keep AI source content on this device. Cloud providers and remote servers are blocked. Download on-device models in Local AI before going offline.")
                }

                Section {
                    NavigationLink(value: Destination.transcription) {
                        defaultRow(
                            "Transcription",
                            icon: "waveform",
                            provider: services.configuration.selectedProvider.title,
                            model: services.configuration.selectedProvider == .localWhisper
                                ? services.llmConfiguration.localAI.whisperModel
                                : services.configuration.openAIModel.title
                        )
                    }
                    .accessibilityIdentifier("settings.transcription")

                    NavigationLink(value: Destination.summary) {
                        defaultRow(
                            "Summaries",
                            icon: "doc.text",
                            provider: services.llmConfiguration.summaryProvider == .openAI && services.llmConfiguration.summaryAuthMethod == .chatGPT
                                ? "ChatGPT"
                                : services.llmConfiguration.summaryProvider.title,
                            model: services.llmConfiguration.summaryProvider == .gemini
                                ? services.llmConfiguration.summaryGeminiModel
                                : services.llmConfiguration.summaryAuthMethod == .chatGPT
                                    ? services.llmConfiguration.summaryChatGPTModel
                                    : services.llmConfiguration.summaryOpenAIModel.title
                        )
                    }
                    .accessibilityIdentifier("settings.summary")

                    NavigationLink(value: Destination.chat) {
                        defaultRow(
                            "Chat",
                            icon: "bubble.left.and.bubble.right",
                            provider: services.llmConfiguration.chatProvider == .openAI && services.llmConfiguration.chatAuthMethod == .chatGPT
                                ? "ChatGPT"
                                : services.llmConfiguration.chatProvider.title,
                            model: services.llmConfiguration.chatProvider == .gemini
                                ? services.llmConfiguration.chatGeminiModel
                                : services.llmConfiguration.chatAuthMethod == .chatGPT
                                    ? services.llmConfiguration.chatChatGPTModel
                                    : services.llmConfiguration.chatOpenAIModel.title
                        )
                    }
                    .accessibilityIdentifier("settings.chat")

                    NavigationLink(value: Destination.presets) {
                        Label("Presets", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("settings.presets")
                } header: {
                    Text("AI Defaults")
                } footer: {
                    Text("Connect accounts in Providers to make them available. Transcription, Summaries, and Chat defaults are independent.")
                }

                Section {
                    NavigationLink(value: Destination.openAI) {
                        providerRow(
                            "OpenAI",
                            brandImage: "OpenAIProvider",
                            templateBrand: true,
                            systemIcon: "sparkles",
                            status: openAIStatusText
                        )
                    }
                    .accessibilityIdentifier("settings.chatgpt")

                    NavigationLink(value: Destination.gemini) {
                        providerRow(
                            "Google / Gemini",
                            brandImage: "GeminiProvider",
                            templateBrand: false,
                            systemIcon: "star",
                            status: geminiStatusText
                        )
                    }
                    .accessibilityIdentifier("settings.gemini")

                    NavigationLink(value: Destination.localAI) {
                        providerRow(
                            "Local AI",
                            brandImage: nil,
                            templateBrand: false,
                            systemIcon: "cpu",
                            status: localAIStatusText,
                            showsLoading: false
                        )
                    }
                    .accessibilityIdentifier("settings.localAI")
                } header: {
                    Text("Providers")
                } footer: {
                    Text("An OpenAI API key enables OpenAI transcription. ChatGPT plan access covers summaries and chat only.")
                }

                Section("Usage") {
                    NavigationLink(value: Destination.usage) {
                        Label("Usage & Costs", systemImage: "dollarsign.circle")
                    }
                    .accessibilityIdentifier("settings.usage")
                }

                Section("Storage, Help & About") {
                    NavigationLink(value: Destination.information(.privacy)) {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                    NavigationLink(value: Destination.information(.help)) {
                        Label("Soniquill Help", systemImage: "questionmark.circle")
                    }
                    NavigationLink(value: Destination.information(.licenses)) {
                        Label("Third-Party Licenses", systemImage: "doc.plaintext")
                    }
                    NavigationLink(value: Destination.about) {
                        LabeledContent {
                            Text("\(ReleaseIdentity().version) (\(ReleaseIdentity().build))")
                        } label: {
                            Label("About Soniquill", systemImage: "info.circle")
                        }
                    }
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .transcription: transcriptionDefaults
                case .summary: summaryDefaults
                case .chat: chatDefaults
                case .defaults: defaultsScreen
                case .presets: PresetsManagementView().navigationTitle("Presets").navigationBarTitleDisplayMode(.inline)
                case .openAI: openAIScreen
                case .openAIKey: openAIKeyScreen
                case .gemini: geminiScreen
                case .localAI: IOSLocalAISettingsView(services: services)
                case .usage: UsageCostView(isEmbedded: true)
                case .information(let page): ReleaseInformationView(page: page)
                case .about: aboutScreen
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--performance-fixtures") {
                    if ProcessInfo.processInfo.arguments.contains("--ios-review-connected-accounts") {
                        reviewAccount = ChatGPTAccount(id: "offline-review", email: "long.synthetic.account.for.layout.review@example.invalid", issuedClientID: "offline-review", grantedScopes: [], planUsageEnabled: true, expiresAt: .distantFuture)
                        geminiAccount = ProviderAccount(provider: .gemini, email: "long.synthetic.account.for.layout.review@example.invalid", authenticationMethod: .oauth, state: .connected)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--ios-review-chatgpt") { path = [.openAI] }
                    if ProcessInfo.processInfo.arguments.contains("--ios-review-gemini") { path = [.gemini] }
                    if ProcessInfo.processInfo.arguments.contains("--ios-local-ai-review") { path = [.localAI] }
                    if ProcessInfo.processInfo.arguments.contains("--ios-review-defaults") { path = [.defaults] }
                    if ProcessInfo.processInfo.arguments.contains("--ios-review-openai-key") { path = [.openAIKey] }
                    if ProcessInfo.processInfo.arguments.contains("--ios-review-usage") { path = [.usage] }
                    isLoadingAccounts = false
                    return
                }
#endif
                await providerSettings.refresh()
                await services.localAISettings.refreshInstalled()
                guard !Task.isCancelled else { return }
                geminiAccount = providerSettings.googleAccount
                isLoadingAccounts = false
                if providerSettings.isChatGPTPlanUsageEnabled { await providerSettings.fetchChatGPTModels() }
            }
        }
    }

    // MARK: - Row Builders & Status

    private var openAIStatusText: String {
        let hasChatGPT = presentedChatGPTAccount != nil
        let hasKey = providerSettings.keyIsConfigured
        switch (hasChatGPT, hasKey) {
        case (true, true): return "ChatGPT + API Key"
        case (true, false): return "ChatGPT"
        case (false, true): return "API Key"
        case (false, false): return "Not Connected"
        }
    }

    private var geminiStatusText: String {
        let hasOAuth = geminiAccount != nil
        let hasKey = providerSettings.geminiKeyIsConfigured
        switch (hasOAuth, hasKey) {
        case (true, true): return "Account + API Key"
        case (true, false): return "Connected"
        case (false, true): return "API Key"
        case (false, false): return "Not Connected"
        }
    }

    private var localAIStatusText: String {
        let count = services.localAISettings.installed.count
        if count == 0 { return "On Device" }
        return count == 1 ? "1 Model Installed" : "\(count) Models Installed"
    }

    private func providerRow(
        _ title: String,
        brandImage: String?,
        templateBrand: Bool,
        systemIcon: String,
        status: String,
        showsLoading: Bool = true
    ) -> some View {
        LabeledContent {
            if showsLoading && isLoadingAccounts {
                ProgressView().accessibilityLabel("Loading account status")
            } else {
                Text(status)
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                if let brandImage {
                    Image(brandImage)
                        .renderingMode(templateBrand ? .template : .original)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.primary)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: systemIcon)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func accountRow(_ title: String, connected: Bool, connectedText: String = "Connected", disconnectedText: String = "Not Connected") -> some View {
        LabeledContent(title) {
            if isLoadingAccounts {
                ProgressView().accessibilityLabel("Loading account status")
            } else {
                Text(connected ? connectedText : disconnectedText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func defaultRow(_ title: String, icon: String, provider: String, model: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(defaultDescription(provider: provider, model: model))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    private func defaultDescription(provider: String, model: String) -> String {
        if provider == LLMProviderID.mock.title { return provider }
        if provider == LLMProviderID.onDevice.title { return provider + " · " + LocalLLMProvider.modelTitle }
        let name = provider == LLMProviderID.openAI.title ? TranscriptionProviderID.openAI.title : provider
        let title = providerSettings.availableChatGPTModels.first(where: { $0.slug == model })?.displayName
            ?? services.llmResolver.summaryModels(for: .gemini).first(where: { $0.id == model })?.title
            ?? services.localAISettings.models.first(where: { $0.id == model }).map { "Whisper " + $0.title }
            ?? model
        return name + " · " + title
    }

    // MARK: - OpenAI Provider Screen (ChatGPT + API Key)

    private var openAIScreen: some View {
        Form {
            Section {
                if isLoadingAccounts {
                    ProgressView("Loading account status…")
                } else if let account = presentedChatGPTAccount {
                    LabeledContent("Status", value: "Connected")
                    LabeledContent("Email") { Text(account.email ?? "ChatGPT account").textSelection(.enabled) }
                    LabeledContent("Plan Access", value: account.planUsageEnabled ? "Authorized" : "Not Authorized")
                    Link(AccountUsageProvider.chatGPT.dashboardTitle, destination: AccountUsageProvider.chatGPT.dashboardURL)
                    Button("Disconnect ChatGPT", role: .destructive) { disconnectChatGPT = true }
                        .disabled(isOfflineReview)
                        .accessibilityIdentifier("settings.chatgpt.disconnect")
                } else {
                    Button(isConnectingAccount ? "Connecting…" : "Sign in with ChatGPT") {
                        Task {
                            isConnectingAccount = true
                            defer { isConnectingAccount = false }
                            await providerSettings.signInWithChatGPT()
                            accountError = providerSettings.chatGPTErrorMessage ?? providerSettings.chatGPTModelsError
                        }
                    }
                    .disabled(isConnectingAccount || isOfflineReview)
                }
            } header: {
                Text("ChatGPT Account (Sign in with ChatGPT)")
            } footer: {
                Text("Connect your ChatGPT subscription (Plus/Team/Pro) to generate summaries and chat without API billing.")
            }

            Section {
                NavigationLink(value: Destination.openAIKey) {
                    LabeledContent {
                        Text(providerSettings.keyIsConfigured ? "Configured" : "Not Configured")
                    } label: {
                        Label("OpenAI API Key", systemImage: providerSettings.keyIsConfigured ? "key.fill" : "key")
                    }
                }
                .accessibilityIdentifier("settings.openai")
            } header: {
                Text("OpenAI Credentials (API Key)")
            } footer: {
                Text("ChatGPT plan access does not cover transcription. Add an OpenAI API key to transcribe with OpenAI (Whisper and GPT-4o Transcribe) or use API-key billing.")
            }

            Section("Usage") {
                NavigationLink(value: Destination.usage) {
                    Text("Soniquill Usage & Costs")
                }
            }

            accountErrorSection
        }
        .navigationTitle("OpenAI")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect ChatGPT?", isPresented: $disconnectChatGPT, titleVisibility: .visible) {
            Button("Disconnect ChatGPT", role: .destructive) {
                Task { do { try await chatGPTAuthService.disconnect() } catch { accountError = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Gemini Provider Screen

    private var geminiScreen: some View {
        Form {
            Section("Google Account (OAuth)") {
                if isLoadingAccounts {
                    ProgressView("Loading account status…")
                } else if let geminiAccount {
                    LabeledContent("Status", value: "Connected")
                    LabeledContent("Email") { Text(geminiAccount.email ?? "Google account").textSelection(.enabled) }
                    Button("Disconnect Google", role: .destructive) { disconnectGemini = true }
                        .disabled(isOfflineReview)
                        .accessibilityIdentifier("settings.gemini.disconnect")
                } else {
                    Button(isConnectingAccount ? "Connecting…" : "Sign in with Google") {
                        Task {
                            isConnectingAccount = true
                            defer { isConnectingAccount = false }
                            do { geminiAccount = try await services.googleGeminiOAuth.connect() }
                            catch { accountError = error.localizedDescription }
                        }
                    }
                    .disabled(isConnectingAccount || isOfflineReview || providerSettings.googleOAuthConfigurationError != nil)
                    if let error = providerSettings.googleOAuthConfigurationError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                accountRow("Gemini Developer API", connected: geminiAccount != nil)
                LabeledContent("Billing", value: "Google Cloud project")
                if !isLoadingAccounts, geminiAccount != nil {
                    NavigationLink(value: Destination.usage) {
                        Text("Soniquill Usage & Costs")
                    }
                    Link(AccountUsageProvider.gemini.dashboardTitle, destination: AccountUsageProvider.gemini.dashboardURL)
                }
            } footer: {
                Text("Google OAuth authorizes Gemini API access for the configured Google Cloud project. Gemini API usage is separate from a consumer Gemini subscription.")
            }

            accountErrorSection
        }
        .navigationTitle("Google / Gemini")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect Google?", isPresented: $disconnectGemini, titleVisibility: .visible) {
            Button("Disconnect Google", role: .destructive) {
                Task {
                    do { try await services.googleGeminiOAuth.disconnect(); geminiAccount = nil }
                    catch { accountError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var accountErrorSection: some View {
        if let accountError { Section { InlineErrorLabel(accountError) } }
    }

    private var defaultsScreen: some View {
        Form {
            Section {
                NavigationLink(value: Destination.transcription) {
                    defaultRow(
                        "Transcription",
                        icon: "waveform",
                        provider: services.configuration.selectedProvider.title,
                        model: services.configuration.selectedProvider == .localWhisper
                            ? services.llmConfiguration.localAI.whisperModel
                            : services.configuration.openAIModel.title
                    )
                }
                NavigationLink(value: Destination.summary) {
                    defaultRow(
                        "Summaries",
                        icon: "doc.text",
                        provider: services.llmConfiguration.summaryProvider == .openAI && services.llmConfiguration.summaryAuthMethod == .chatGPT
                            ? "ChatGPT"
                            : services.llmConfiguration.summaryProvider.title,
                        model: services.llmConfiguration.summaryProvider == .gemini
                            ? services.llmConfiguration.summaryGeminiModel
                            : services.llmConfiguration.summaryAuthMethod == .chatGPT
                                ? services.llmConfiguration.summaryChatGPTModel
                                : services.llmConfiguration.summaryOpenAIModel.title
                    )
                }
                NavigationLink(value: Destination.chat) {
                    defaultRow(
                        "Chat",
                        icon: "bubble.left.and.bubble.right",
                        provider: services.llmConfiguration.chatProvider == .openAI && services.llmConfiguration.chatAuthMethod == .chatGPT
                            ? "ChatGPT"
                            : services.llmConfiguration.chatProvider.title,
                        model: services.llmConfiguration.chatProvider == .gemini
                            ? services.llmConfiguration.chatGeminiModel
                            : services.llmConfiguration.chatAuthMethod == .chatGPT
                                ? services.llmConfiguration.chatChatGPTModel
                                : services.llmConfiguration.chatOpenAIModel.title
                    )
                }
            } footer: {
                Text("Connect accounts to make their providers available. Summary and Chat defaults are independent.")
            }
        }
        .navigationTitle("AI Defaults")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - OpenAI API Key

    private var openAIKeyScreen: some View {
        IOSOpenAIAPIKeyView(settings: providerSettings, isOfflineReview: isOfflineReview) {
            if !availableTranscriptionProviders.contains(services.configuration.selectedProvider) {
                services.configuration.selectedProvider = .openAI
            }
        }
    }

    // MARK: - Generation Defaults (Unified with macOS GenerationDefaultsView)

    private var summaryDefaults: some View {
        Form {
            Section("Summaries") {
                Picker("Provider", selection: Binding<LLMProviderID?>(
                    get: { availableLLMProviders.contains(services.llmConfiguration.summaryProvider) ? Optional(services.llmConfiguration.summaryProvider) : nil },
                    set: { selection in
                        guard let newProvider = selection else { return }
                        services.llmConfiguration.summaryProvider = newProvider
                        if newProvider == .gemini { services.llmConfiguration.summaryGeminiAuthenticationMethod = .oauth }
                        if newProvider == .openAI {
                            if presentedChatGPTAccount?.planUsageEnabled == true {
                                services.llmConfiguration.summaryAuthMethod = .chatGPT
                            } else if providerSettings.keyIsConfigured {
                                services.llmConfiguration.summaryAuthMethod = .apiKey
                            }
                        }
                    }
                )) {
                    Text("Choose a connected provider").tag(Optional<LLMProviderID>.none)
                    ForEach(availableLLMProviders) { provider in
                        Text(provider.title).tag(Optional(provider))
                    }
                }

                if services.llmConfiguration.summaryProvider == .openAI {
                    Picker("Authentication", selection: Binding(
                        get: { services.llmConfiguration.summaryAuthMethod },
                        set: { services.llmConfiguration.summaryAuthMethod = $0 }
                    )) {
                        if providerSettings.keyIsConfigured { Text("OpenAI API").tag(OpenAIAuthenticationMethod.apiKey) }
                        if presentedChatGPTAccount?.planUsageEnabled == true { Text("ChatGPT Plan").tag(OpenAIAuthenticationMethod.chatGPT) }
                    }
                    if services.llmConfiguration.summaryAuthMethod == .chatGPT {
                        Picker("Model", selection: Binding(
                            get: { services.llmConfiguration.summaryChatGPTModel },
                            set: { services.llmConfiguration.summaryChatGPTModel = $0 }
                        )) {
                            ForEach(providerSettings.availableChatGPTModels) { model in
                                Text(model.displayName).tag(model.slug)
                            }
                        }
                        if providerSettings.isFetchingChatGPTModels {
                            HStack { ProgressView(); Text("Fetching ChatGPT models…").foregroundStyle(.secondary) }
                        } else if presentedChatGPTAccount != nil {
                            Button("Refresh ChatGPT Models") { Task { await providerSettings.fetchChatGPTModels() } }
                                .disabled(isOfflineReview)
                        }
                        if let error = providerSettings.chatGPTModelsError { InlineErrorLabel(error) }
                    } else {
                        Picker("Model", selection: Binding(
                            get: { services.llmConfiguration.summaryOpenAIModel },
                            set: { services.llmConfiguration.summaryOpenAIModel = $0 }
                        )) {
                            ForEach(OpenAILLMModel.allCases) { model in Text(model.title).tag(model) }
                        }
                    }
                }

                if services.llmConfiguration.summaryProvider == .gemini {
                    Picker("Model", selection: Binding(
                        get: { services.llmConfiguration.summaryGeminiModel },
                        set: { services.llmConfiguration.summaryGeminiModel = $0 }
                    )) {
                        Text("Gemini 3.8 Flash").tag("gemini-3.8-flash")
                    }
                    Text("Gemini Developer API use is billed to the configured Google Cloud project. Gemini Advanced does not pay API charges.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Picker("Detail Level", selection: Binding(
                    get: { services.llmConfiguration.summaryOutputLength },
                    set: { services.llmConfiguration.summaryOutputLength = $0 }
                )) {
                    ForEach(OutputLength.allCases) { Text($0.title).tag($0) }
                }

                if services.llmConfiguration.summaryCapabilities.supportsMaxOutputTokens || services.llmConfiguration.summaryCapabilities.supportsTemperature {
                    DisclosureGroup("Advanced Summary Settings", isExpanded: $showAdvancedSummary) {
                        if services.llmConfiguration.summaryCapabilities.supportsMaxOutputTokens {
                            LabeledContent("Max output tokens") {
                                TextField("Tokens", value: Binding(
                                    get: { services.llmConfiguration.summarySettings.maxOutputTokens ?? 4000 },
                                    set: { value in
                                        var settings = services.llmConfiguration.summarySettings
                                        settings.maxOutputTokens = max(1, value)
                                        services.llmConfiguration.summarySettings = settings
                                    }
                                ), format: .number)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                            }
                        }
                        if services.llmConfiguration.summaryCapabilities.supportsTemperature {
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent("Temperature", value: String(format: "%.2f", services.llmConfiguration.summarySettings.temperature ?? 0.3))
                                    .monospacedDigit()
                                Slider(
                                    value: Binding(
                                        get: { services.llmConfiguration.summarySettings.temperature ?? 0.3 },
                                        set: { val in
                                            var current = services.llmConfiguration.summarySettings
                                            current.temperature = val
                                            services.llmConfiguration.summarySettings = current
                                        }
                                    ),
                                    in: 0.0...2.0,
                                    step: 0.05
                                )
                            }
                        }
                    }
                }
            }

            if !isLoadingAccounts, presentedChatGPTAccount == nil, !providerSettings.keyIsConfigured {
                Section {
                    NavigationLink(value: Destination.openAI) {
                        Label("Connect OpenAI or ChatGPT", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
        }
        .navigationTitle("Summary Defaults")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chatDefaults: some View {
        Form {
            Section("Chat") {
                Picker("Provider", selection: Binding<LLMProviderID?>(
                    get: { availableLLMProviders.contains(services.llmConfiguration.chatProvider) ? Optional(services.llmConfiguration.chatProvider) : nil },
                    set: { selection in
                        guard let newProvider = selection else { return }
                        services.llmConfiguration.chatProvider = newProvider
                        if newProvider == .gemini { services.llmConfiguration.chatGeminiAuthenticationMethod = .oauth }
                        if newProvider == .openAI {
                            if presentedChatGPTAccount?.planUsageEnabled == true {
                                services.llmConfiguration.chatAuthMethod = .chatGPT
                            } else if providerSettings.keyIsConfigured {
                                services.llmConfiguration.chatAuthMethod = .apiKey
                            }
                        }
                    }
                )) {
                    Text("Choose a connected provider").tag(Optional<LLMProviderID>.none)
                    ForEach(availableLLMProviders) { provider in
                        Text(provider.title).tag(Optional(provider))
                    }
                }

                if services.llmConfiguration.chatProvider == .openAI {
                    Picker("Authentication", selection: Binding(
                        get: { services.llmConfiguration.chatAuthMethod },
                        set: { services.llmConfiguration.chatAuthMethod = $0 }
                    )) {
                        if providerSettings.keyIsConfigured { Text("OpenAI API").tag(OpenAIAuthenticationMethod.apiKey) }
                        if presentedChatGPTAccount?.planUsageEnabled == true { Text("ChatGPT Plan").tag(OpenAIAuthenticationMethod.chatGPT) }
                    }
                    if services.llmConfiguration.chatAuthMethod == .chatGPT {
                        Picker("Model", selection: Binding(
                            get: { services.llmConfiguration.chatChatGPTModel },
                            set: { services.llmConfiguration.chatChatGPTModel = $0 }
                        )) {
                            ForEach(providerSettings.availableChatGPTModels) { model in
                                Text(model.displayName).tag(model.slug)
                            }
                        }
                        if providerSettings.isFetchingChatGPTModels {
                            HStack { ProgressView(); Text("Fetching ChatGPT models…").foregroundStyle(.secondary) }
                        } else if presentedChatGPTAccount != nil {
                            Button("Refresh ChatGPT Models") { Task { await providerSettings.fetchChatGPTModels() } }
                                .disabled(isOfflineReview)
                        }
                        if let error = providerSettings.chatGPTModelsError { InlineErrorLabel(error) }
                        Text("Chat uses your ChatGPT account. It will not fall back to API-key billing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: Binding(
                            get: { services.llmConfiguration.chatOpenAIModel },
                            set: { services.llmConfiguration.chatOpenAIModel = $0 }
                        )) {
                            ForEach(OpenAILLMModel.allCases) { model in Text(model.title).tag(model) }
                        }
                        Text("Chat is billed per token by OpenAI. Responses use reasoning where supported.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if services.llmConfiguration.chatProvider == .gemini {
                    Picker("Model", selection: Binding(
                        get: { services.llmConfiguration.chatGeminiModel },
                        set: { services.llmConfiguration.chatGeminiModel = $0 }
                    )) {
                        Text("Gemini 3.8 Flash").tag("gemini-3.8-flash")
                    }
                    Text("Gemini Developer API use is billed to the configured Google Cloud project. Gemini Advanced does not pay API charges.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Picker("Response length", selection: Binding(
                    get: { services.llmConfiguration.chatOutputLength },
                    set: { services.llmConfiguration.chatOutputLength = $0 }
                )) {
                    ForEach(OutputLength.allCases) { Text($0.title).tag($0) }
                }

                if services.llmConfiguration.chatCapabilities.supportsMaxOutputTokens || services.llmConfiguration.chatCapabilities.supportsTemperature {
                    DisclosureGroup("Advanced Chat Settings", isExpanded: $showAdvancedChat) {
                        if services.llmConfiguration.chatCapabilities.supportsMaxOutputTokens {
                            LabeledContent("Max output tokens") {
                                TextField("Tokens", value: Binding(
                                    get: { services.llmConfiguration.chatSettings.maxOutputTokens ?? 6000 },
                                    set: { value in
                                        var settings = services.llmConfiguration.chatSettings
                                        settings.maxOutputTokens = max(1, value)
                                        services.llmConfiguration.chatSettings = settings
                                    }
                                ), format: .number)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                            }
                        }
                        if services.llmConfiguration.chatCapabilities.supportsTemperature {
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent("Temperature", value: String(format: "%.2f", services.llmConfiguration.chatSettings.temperature ?? 0.7))
                                    .monospacedDigit()
                                Slider(
                                    value: Binding(
                                        get: { services.llmConfiguration.chatSettings.temperature ?? 0.7 },
                                        set: { val in
                                            var current = services.llmConfiguration.chatSettings
                                            current.temperature = val
                                            services.llmConfiguration.chatSettings = current
                                        }
                                    ),
                                    in: 0.0...2.0,
                                    step: 0.05
                                )
                            }
                        }
                    }
                }
            }

            if !isLoadingAccounts, presentedChatGPTAccount == nil, !providerSettings.keyIsConfigured {
                Section {
                    NavigationLink(value: Destination.openAI) {
                        Label("Connect OpenAI or ChatGPT", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
        }
        .navigationTitle("Chat Defaults")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var transcriptionDefaults: some View {
        Form {
            Section("Transcription") {
                Picker("Provider", selection: Binding<TranscriptionProviderID?>(
                    get: { availableTranscriptionProviders.contains(services.configuration.selectedProvider) ? Optional(services.configuration.selectedProvider) : nil },
                    set: { if let provider = $0 { services.configuration.selectedProvider = provider } }
                )) {
                    Text("Choose a connected provider").tag(Optional<TranscriptionProviderID>.none)
                    ForEach(availableTranscriptionProviders) { provider in
                        Text(provider.title).tag(Optional(provider))
                    }
                }

                if services.configuration.selectedProvider == .localWhisper {
                    Picker("On-device Model", selection: Binding(
                        get: { services.llmConfiguration.localAI.whisperModel },
                        set: { services.llmConfiguration.localAI.whisperModel = $0 }
                    )) {
                        ForEach(services.localAISettings.models) { Text("Whisper " + $0.title).tag($0.id) }
                    }
                    Picker("Language", selection: Binding(
                        get: { services.llmConfiguration.localAI.whisperLanguage },
                        set: { services.llmConfiguration.localAI.whisperLanguage = $0 }
                    )) {
                        Text("Automatic detection").tag("")
                        ForEach(LocalAISettingsViewModel.languages, id: \.self) { code in
                            Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                        }
                    }
                    NavigationLink(value: Destination.localAI) {
                        Text("Manage Whisper Models")
                    }
                    Text("No audio upload. Download a model explicitly before transcribing.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if services.configuration.selectedProvider == .openAI {
                    Picker("Model", selection: Binding(
                        get: { services.configuration.openAIModel },
                        set: { services.configuration.openAIModel = $0 }
                    )) {
                        ForEach(openAITranscriptionModels) { model in
                            Text(model.title).tag(model)
                        }
                    }
                    if providerSettings.isFetchingTranscriptionModels {
                        HStack { ProgressView(); Text("Fetching voice models…").foregroundStyle(.secondary) }
                    } else if providerSettings.keyIsConfigured {
                        Button("Refresh Voice Models") { Task { await providerSettings.fetchVoiceModels() } }
                            .disabled(isOfflineReview)
                    }
                    if let error = providerSettings.transcriptionModelsError { InlineErrorLabel(error) }

                    Picker("Audio Language", selection: Binding(
                        get: { services.configuration.language },
                        set: { services.configuration.language = $0 }
                    )) {
                        ForEach(TranscriptionLanguage.allCases) { lang in
                            Text(lang.title).tag(lang)
                        }
                    }
                    Text("Whisper-1 supplies segment timestamps for playback seeking. Audio is uploaded to OpenAI and billed per minute; larger recordings are split automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

            }

            if !isLoadingAccounts, !providerSettings.keyIsConfigured {
                Section {
                    NavigationLink(value: Destination.openAIKey) {
                        Label("Add OpenAI API Key", systemImage: "key")
                    }
                    .accessibilityIdentifier("settings.transcription.addOpenAIKey")
                } footer: {
                    Text("An OpenAI API key enables OpenAI transcription (Whisper and GPT-4o Transcribe). ChatGPT plan sign-in does not cover transcription.")
                }
            }
        }
        .navigationTitle("Transcription Defaults")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Account-fetched voice models, always including the saved selection so the picker never loses its tag.
    private var openAITranscriptionModels: [OpenAITranscriptionModel] {
        var models = providerSettings.availableTranscriptionModels
        if models.isEmpty { models = OpenAITranscriptionModel.standardModels }
        if !models.contains(services.configuration.openAIModel) { models.append(services.configuration.openAIModel) }
        return models
    }

    // MARK: - About

    private var aboutScreen: some View {
        Form {
            Section("About Soniquill") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Soniquill \(ReleaseIdentity().version) (\(ReleaseIdentity().build))")
                        .font(.headline)
                    Text("Native audio transcription, AI summaries, and interactive transcript chat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                LabeledContent("Application", value: "Soniquill")
                LabeledContent("Version", value: ReleaseIdentity().version)
                LabeledContent("Build", value: ReleaseIdentity().build)
                LabeledContent("Platform Shell", value: "Native iOS & iPadOS")
            }

            Section("Information") {
                NavigationLink(value: Destination.information(.privacy)) {
                    Label("Privacy", systemImage: "hand.raised")
                }
                NavigationLink(value: Destination.information(.help)) {
                    Label("Soniquill Help", systemImage: "questionmark.circle")
                }
                NavigationLink(value: Destination.information(.licenses)) {
                    Label("Third-Party Licenses", systemImage: "doc.plaintext")
                }
            }

#if DEBUG
            Section("Development") {
                Button(providerSettings.copiedLogsNotice ? "Copied Debug Logs" : "Copy Debug Logs") {
                    providerSettings.copyLogs()
                }
            }
#endif
        }
        .navigationTitle("About Soniquill")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var availableTranscriptionProviders: [TranscriptionProviderID] {
        IOSProviderAvailability.transcription(
            openAIKey: providerSettings.keyIsConfigured,
            includeMock: services.configuration.selectedProvider == .mock,
            localWhisperSupported: LocalAISettingsViewModel.supportsWhisper
        )
    }

    private var availableLLMProviders: [LLMProviderID] {
        var providers: [LLMProviderID] = []
        if PlatformCapabilities.current.isSupported(llmProvider: .onDevice) { providers.append(.onDevice) }
#if DEBUG
        if services.llmConfiguration.summaryProvider == .mock || services.llmConfiguration.chatProvider == .mock { providers.append(.mock) }
#endif
        if providerSettings.keyIsConfigured || presentedChatGPTAccount?.planUsageEnabled == true { providers.append(.openAI) }
        if geminiAccount != nil { providers.append(.gemini) }
        return providers
    }
}
#endif
