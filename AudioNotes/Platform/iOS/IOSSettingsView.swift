#if os(iOS)
import SwiftUI

struct IOSSettingsView: View {
    let services: AppServices
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        case privacy
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
        case .privacy: return [.privacy]
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
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    List { overviewSections }
                        .listStyle(.sidebar)
                        .navigationTitle("Settings")
                        .toolbar { doneItem }
                } detail: {
                    NavigationStack(path: detailPath) {
                        let selection = path.first ?? .transcription
                        destinationView(selection)
                            .id(selection)
                            .navigationDestination(for: Destination.self, destination: destinationView)
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack(path: $path) {
                    Form { overviewSections }
                        .navigationDestination(for: Destination.self, destination: destinationView)
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { doneItem }
                }
            }
        }
        .presentationSizing(.page)
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
        }
    }

    private var detailPath: Binding<[Destination]> {
        Binding(
            get: { Array(path.dropFirst()) },
            set: { detail in
                guard !detail.isEmpty || !path.isEmpty else { return }
                path = [path.first ?? .transcription] + detail
            }
        )
    }

    private var doneItem: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
    }

    @ViewBuilder
    private func rootLink<Content: View>(_ destination: Destination, @ViewBuilder content: () -> Content) -> some View {
        if horizontalSizeClass == .regular {
            let isSelected = (path.first ?? .transcription) == destination
            Button { path = [destination] } label: {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .listRowBackground(isSelected ? Color.accentColor.opacity(0.14) : nil)
        } else {
            NavigationLink(value: destination, label: content)
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: Destination) -> some View {
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
        case .privacy: privacyScreen
        case .about: aboutScreen
        }
    }

    @ViewBuilder
    private var overviewSections: some View {
        Section {
            rootLink(.transcription) {
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

            rootLink(.summary) {
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

            rootLink(.chat) {
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

            rootLink(.presets) {
                Label("Presets", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("settings.presets")
        } header: {
            Text("AI Defaults")
        }

        Section {
            rootLink(.openAI) {
                providerRow(
                    "OpenAI",
                    brandImage: "OpenAIProvider",
                    templateBrand: true,
                    systemIcon: "sparkles",
                    status: openAIStatusText
                )
            }
            .accessibilityIdentifier("settings.chatgpt")

            rootLink(.gemini) {
                providerRow(
                    "Google / Gemini",
                    brandImage: "GeminiProvider",
                    templateBrand: false,
                    systemIcon: "star",
                    status: geminiStatusText
                )
            }
            .accessibilityIdentifier("settings.gemini")

            rootLink(.localAI) {
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
            Text("Connections & Models")
        }

        Section("Usage") {
            rootLink(.usage) {
                Label("Usage & Costs", systemImage: "dollarsign.circle")
            }
            .accessibilityIdentifier("settings.usage")
        }

        Section("Soniquill") {
            rootLink(.privacy) { Label("Privacy & Data", systemImage: "hand.raised") }
            rootLink(.about) { Label("Help & About", systemImage: "info.circle") }
        }
    }

    private var privacyScreen: some View {
        Form {
            Section {
                Toggle("Local Only", isOn: Binding(
                    get: { services.llmConfiguration.localAI.localOnly },
                    set: { services.llmConfiguration.localAI.localOnly = $0 }
                ))
                .accessibilityIdentifier("settings.localOnly")
                NavigationLink(value: Destination.localAI) {
                    Label("Manage Local Models", systemImage: "cpu")
                }
            } header: {
                Text("AI Privacy")
            } footer: {
                Text("Local Only keeps AI source content on this device by blocking cloud providers and remote servers.")
            }

            Section("Data") {
                NavigationLink(value: Destination.information(.privacy)) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }
        }
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.inline)
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
        if count == 0 { return "No Whisper Models Installed" }
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
        let label = Label {
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
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    label
                    providerStatus(status, showsLoading: showsLoading)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent {
                    providerStatus(status, showsLoading: showsLoading)
                } label: { label }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func providerStatus(_ status: String, showsLoading: Bool) -> some View {
        if showsLoading && isLoadingAccounts {
            ProgressView().accessibilityLabel("Loading account status")
        } else {
            Text(status)
        }
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
                    LabeledContent("Status", value: "Not Connected")
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
                Text("ChatGPT Account")
            } footer: {
                Text("Use your ChatGPT plan for summaries and chat.")
            }

            Section {
                LabeledContent("Status", value: providerSettings.keyIsConfigured ? "Configured" : "Not Configured")
                NavigationLink(value: Destination.openAIKey) {
                    Text(providerSettings.keyIsConfigured ? "Manage API Key" : "Add API Key")
                }
                .accessibilityIdentifier("settings.openai")
            } header: {
                Text("OpenAI API Key")
            } footer: {
                Text("Enables transcription, summaries, and chat with OpenAI API billing.")
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
            Section {
                if isLoadingAccounts {
                    ProgressView("Loading account status…")
                } else if let geminiAccount {
                    LabeledContent("Status", value: "Connected")
                    LabeledContent("Account") { Text(geminiAccount.email ?? "Google account").textSelection(.enabled) }
                    Button("Disconnect Google", role: .destructive) { disconnectGemini = true }
                        .disabled(isOfflineReview)
                        .accessibilityIdentifier("settings.gemini.disconnect")
                } else {
                    LabeledContent("Status", value: "Not Connected")
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
            } header: {
                Text("Google Account")
            } footer: {
                Text("Your Google account authorizes Gemini API access for summaries and chat.")
            }

            Section {
                LabeledContent("API Billing", value: "Google Cloud project")
                if !isLoadingAccounts, geminiAccount != nil {
                    NavigationLink(value: Destination.usage) {
                        Text("Soniquill Usage & Costs")
                    }
                    Link(AccountUsageProvider.gemini.dashboardTitle, destination: AccountUsageProvider.gemini.dashboardURL)
                }
            } header: {
                Text("Usage")
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

    @ViewBuilder
    private func openAIConnectionRow(selection: Binding<OpenAIAuthenticationMethod>) -> some View {
        let methods = OpenAIAuthenticationMethod.allCases.filter { method in
            switch method {
            case .apiKey: providerSettings.keyIsConfigured
            case .chatGPT: presentedChatGPTAccount?.planUsageEnabled == true
            }
        }
        if methods == [selection.wrappedValue] {
            LabeledContent("Connection", value: selection.wrappedValue.title)
        } else if !methods.isEmpty {
            Picker("Connection", selection: selection) {
                if !methods.contains(selection.wrappedValue) {
                    Text(selection.wrappedValue.title + " (Unavailable)").tag(selection.wrappedValue)
                }
                ForEach(methods) { Text($0.title).tag($0) }
            }
        }
    }

    private var summaryDefaults: some View {
        Form {
            Section("Model") {
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
                    openAIConnectionRow(selection: Binding(
                        get: { services.llmConfiguration.summaryAuthMethod },
                        set: { services.llmConfiguration.summaryAuthMethod = $0 }
                    ))
                    if services.llmConfiguration.summaryAuthMethod == .chatGPT {
                        Picker("Model", selection: Binding(
                            get: { services.llmConfiguration.summaryChatGPTModel },
                            set: { services.llmConfiguration.summaryChatGPTModel = $0 }
                        )) {
                            ForEach(providerSettings.availableChatGPTModels) { model in
                                Text(model.displayName).tag(model.slug)
                            }
                        }
                        .pickerStyle(.navigationLink)
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
                        .pickerStyle(.navigationLink)
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
            }

            Section("Output") {
                Picker("Detail Level", selection: Binding(
                    get: { services.llmConfiguration.summaryOutputLength },
                    set: { services.llmConfiguration.summaryOutputLength = $0 }
                )) {
                    ForEach(OutputLength.allCases) { Text($0.title).tag($0) }
                }
            }

            if services.llmConfiguration.summaryCapabilities.supportsMaxOutputTokens || services.llmConfiguration.summaryCapabilities.supportsTemperature {
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvancedSummary) {
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
            Section("Model") {
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
                    openAIConnectionRow(selection: Binding(
                        get: { services.llmConfiguration.chatAuthMethod },
                        set: { services.llmConfiguration.chatAuthMethod = $0 }
                    ))
                    if services.llmConfiguration.chatAuthMethod == .chatGPT {
                        Picker("Model", selection: Binding(
                            get: { services.llmConfiguration.chatChatGPTModel },
                            set: { services.llmConfiguration.chatChatGPTModel = $0 }
                        )) {
                            ForEach(providerSettings.availableChatGPTModels) { model in
                                Text(model.displayName).tag(model.slug)
                            }
                        }
                        .pickerStyle(.navigationLink)
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
                        .pickerStyle(.navigationLink)
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
            }

            Section("Output") {
                Picker("Response length", selection: Binding(
                    get: { services.llmConfiguration.chatOutputLength },
                    set: { services.llmConfiguration.chatOutputLength = $0 }
                )) {
                    ForEach(OutputLength.allCases) { Text($0.title).tag($0) }
                }
            }

            if services.llmConfiguration.chatCapabilities.supportsMaxOutputTokens || services.llmConfiguration.chatCapabilities.supportsTemperature {
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvancedChat) {
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
            Section {
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
                    Picker("Model", selection: Binding(
                        get: { services.llmConfiguration.localAI.whisperModel },
                        set: { services.llmConfiguration.localAI.whisperModel = $0 }
                    )) {
                        ForEach(services.localAISettings.models) { Text("Whisper " + $0.title).tag($0.id) }
                    }
                    if !services.localAISettings.installed.contains(services.llmConfiguration.localAI.whisperModel) {
                        NavigationLink(value: Destination.localAI) { Text("Manage Whisper Models") }
                    }
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

                }

                if !isLoadingAccounts, !providerSettings.keyIsConfigured,
                   services.configuration.selectedProvider == .openAI {
                    NavigationLink(value: Destination.openAIKey) {
                        Label("Set Up OpenAI API Key", systemImage: "key")
                    }
                    .accessibilityIdentifier("settings.transcription.addOpenAIKey")
                }
            } header: {
                Text("Transcription Service")
            } footer: {
                switch services.configuration.selectedProvider {
                case .mock:
                    Text("Generates sample transcripts locally for development.")
                case .localWhisper:
                    Text("Processes audio on this device and provides segment timestamps.")
                case .openAI:
                    Text(services.configuration.openAIModel.supportsSegmentTimestamps
                         ? "Provides segment timestamps for playback. Audio is sent to OpenAI for API billing."
                         : "Returns transcript text. Audio is sent to OpenAI for API billing.")
                }
            }

            if services.configuration.selectedProvider == .localWhisper {
                Section("Audio") {
                    Picker("Language", selection: Binding(
                        get: { services.llmConfiguration.localAI.whisperLanguage },
                        set: { services.llmConfiguration.localAI.whisperLanguage = $0 }
                    )) {
                        Text("Automatic detection").tag("")
                        ForEach(LocalAISettingsViewModel.languages, id: \.self) { code in
                            Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                        }
                    }
                }
            } else if services.configuration.selectedProvider == .openAI {
                Section("Audio") {
                    Picker("Language", selection: Binding(
                        get: { services.configuration.language },
                        set: { services.configuration.language = $0 }
                    )) {
                        ForEach(TranscriptionLanguage.allCases) { lang in
                            Text(lang.title).tag(lang)
                        }
                    }
                }
            }

            if !isLoadingAccounts, !providerSettings.keyIsConfigured,
               services.configuration.selectedProvider != .openAI {
                Section {
                    NavigationLink(value: Destination.openAIKey) {
                        Label("Set Up OpenAI API Key", systemImage: "key")
                    }
                    .accessibilityIdentifier("settings.transcription.addOpenAIKey")
                } footer: {
                    Text("An API key enables cloud transcription with OpenAI.")
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
            Section("Help") {
                NavigationLink(value: Destination.information(.help)) {
                    Label("Soniquill Help", systemImage: "questionmark.circle")
                }
                NavigationLink(value: Destination.information(.licenses)) {
                    Label("Third-Party Licenses", systemImage: "doc.plaintext")
                }
            }

            Section("About Soniquill") {
                LabeledContent("Version & Build", value: "\(ReleaseIdentity().version) (\(ReleaseIdentity().build))")
            }

#if DEBUG
            Section("Development") {
                Button(providerSettings.copiedLogsNotice ? "Copied Debug Logs" : "Copy Debug Logs") {
                    providerSettings.copyLogs()
                }
            }
#endif
        }
        .navigationTitle("Help & About")
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
