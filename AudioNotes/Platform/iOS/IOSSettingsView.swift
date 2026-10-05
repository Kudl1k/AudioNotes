#if os(iOS)
import SwiftUI

struct IOSSettingsView: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var providerSettings: ProviderSettingsViewModel
    @State private var showingRemoveConfirmation = false
    @State private var showingUsage = false
    @State private var disconnectChatGPT = false
    @State private var disconnectGemini = false
#if DEBUG
    @State private var reviewAccount: ChatGPTAccount?
#endif
    @State private var geminiAccount: ProviderAccount?
    @State private var accountError: String?
    @State private var isConnectingAccount = false
    @ObservedObject private var chatGPTAuthService: ChatGPTAuthService

    init(services: AppServices) {
        self.services = services
        _chatGPTAuthService = ObservedObject(wrappedValue: services.chatGPTAuthService)
        _providerSettings = State(initialValue: ProviderSettingsViewModel(
            credentials: services.credentials,
            chatGPTAuth: services.chatGPTAuthService,
            tokenRefresher: services.chatGPTTokenRefresher,
            modelsClient: services.modelsClient,
            transcriptionConfig: services.configuration,
            llmConfig: services.llmConfiguration,
            googleOAuth: services.googleGeminiOAuth
        ))
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

    private enum Destination: Hashable { case chatGPT, gemini, defaults }
    @State private var path: [Destination] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section("Accounts") {
                    NavigationLink { chatGPTScreen } label: {
                        accountRow("ChatGPT", connected: presentedChatGPTAccount != nil)
                    }.accessibilityIdentifier("settings.chatgpt")
                    NavigationLink { geminiScreen } label: {
                        accountRow("Google / Gemini", connected: geminiAccount != nil)
                    }.accessibilityIdentifier("settings.gemini")
                }
                Section("AI") {
                    NavigationLink("Defaults") { defaultsScreen }.accessibilityIdentifier("settings.defaults")
                    NavigationLink("Presets") { PresetsManagementView().navigationTitle("Presets") }
                }
                Section("Usage") {
                    Button("Usage & Costs") { showingUsage = true }.accessibilityIdentifier("settings.usage")
                }
                Section("About") {
                    NavigationLink("About AudioNotes") { Form { aboutSection }.navigationTitle("About AudioNotes") }
                }
            }
            .sheet(isPresented: $showingUsage) { UsageCostView() }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .chatGPT: chatGPTScreen
                case .gemini: geminiScreen
                case .defaults: defaultsScreen
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
                    if ProcessInfo.processInfo.arguments.contains("--ios-review-chatgpt") { path = [.chatGPT] }
                    if ProcessInfo.processInfo.arguments.contains("--ios-review-gemini") { path = [.gemini] }
                    if ProcessInfo.processInfo.arguments.contains("--ios-review-defaults") { path = [.defaults] }
                    if ProcessInfo.processInfo.arguments.contains("--ios-review-usage") { showingUsage = true }
                    return
                }
#endif
                await providerSettings.refresh()
                await chatGPTAuthService.restoreSession()
                if providerSettings.isChatGPTPlanUsageEnabled { await providerSettings.fetchChatGPTModels() }
                geminiAccount = await services.googleGeminiOAuth.account()
            }
            .confirmationDialog(
                "Remove OpenAI API Key?",
                isPresented: $showingRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove API Key", role: .destructive) {
                    Task {
                        await providerSettings.removeKey()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your API key will be permanently removed from this device's Keychain. You will need to re-enter it to use OpenAI transcription, summary, or chat.")
            }
        }
    }

    private func accountRow(_ title: String, connected: Bool) -> some View {
        LabeledContent(title, value: connected ? "Connected" : "Not Connected")
            .accessibilityElement(children: .combine)
    }

    private var chatGPTScreen: some View {
        Form {
            Section("Account") {
                if let account = presentedChatGPTAccount {
                    LabeledContent("Status", value: "Connected")
                    LabeledContent("Email") { Text(account.email ?? "ChatGPT account").textSelection(.enabled) }
                    LabeledContent("Plan Access", value: account.planUsageEnabled ? "Authorized" : "Not Authorized")
                    Link("Manage Plan Usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                } else {
                    Button(isConnectingAccount ? "Connecting…" : "Continue with ChatGPT") {
                        Task {
                            isConnectingAccount = true
                            defer { isConnectingAccount = false }
                            do { try await chatGPTAuthService.signIn(); await providerSettings.fetchChatGPTModels() }
                            catch { accountError = error.localizedDescription }
                        }
                    }.disabled(isConnectingAccount || isOfflineReview)
                }
            }
            Section {
                NavigationLink { Form { openAISection }.navigationTitle("OpenAI API Key") } label: {
                    LabeledContent("API Key", value: providerSettings.keyIsConfigured ? "Configured" : "Not Configured")
                }
            } header: { Text("API Access") } footer: {
                Text("API keys are optional and enable OpenAI API features such as transcription. API usage is billed separately from ChatGPT plan access.")
            }
            if presentedChatGPTAccount != nil {
                Section { Button("Disconnect ChatGPT", role: .destructive) { disconnectChatGPT = true }.disabled(isOfflineReview).accessibilityIdentifier("settings.chatgpt.disconnect") }
            }
            accountErrorSection
        }
        .navigationTitle("ChatGPT").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect ChatGPT?", isPresented: $disconnectChatGPT, titleVisibility: .visible) {
            Button("Disconnect ChatGPT", role: .destructive) {
                Task { do { try await chatGPTAuthService.disconnect() } catch { accountError = error.localizedDescription } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var geminiScreen: some View {
        Form {
            Section("Account") {
                if let geminiAccount {
                    LabeledContent("Status", value: "Connected")
                    LabeledContent("Email") { Text(geminiAccount.email ?? "Google account").textSelection(.enabled) }
                } else {
                    Button(isConnectingAccount ? "Connecting…" : "Continue with Google") {
                        Task {
                            isConnectingAccount = true
                            defer { isConnectingAccount = false }
                            do { geminiAccount = try await services.googleGeminiOAuth.connect() }
                            catch { accountError = error.localizedDescription }
                        }
                    }.disabled(isConnectingAccount || isOfflineReview || providerSettings.googleOAuthConfigurationError != nil)
                    if let error = providerSettings.googleOAuthConfigurationError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            Section {
                LabeledContent("Gemini Developer API", value: geminiAccount == nil ? "Not Connected" : "Connected")
                LabeledContent("Billing", value: "Google Cloud project")
            } footer: { Text("Gemini API usage is separate from your Gemini consumer subscription.") }
            if geminiAccount != nil {
                Section { Button("Disconnect Google", role: .destructive) { disconnectGemini = true }.disabled(isOfflineReview).accessibilityIdentifier("settings.gemini.disconnect") }
            }
            accountErrorSection
        }
        .navigationTitle("Google / Gemini").navigationBarTitleDisplayMode(.inline)
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
                NavigationLink { transcriptionDefaults } label: { defaultRow("Transcription", provider: services.configuration.selectedProvider.title, model: services.configuration.selectedProvider == .gemini ? services.configuration.geminiModel : services.configuration.openAIModel.title) }
                NavigationLink { summaryDefaults } label: { defaultRow("Summary", provider: services.llmConfiguration.summaryProvider == .openAI && services.llmConfiguration.summaryAuthMethod == .chatGPT ? "ChatGPT" : services.llmConfiguration.summaryProvider.title, model: services.llmConfiguration.summaryProvider == .gemini ? services.llmConfiguration.summaryGeminiModel : services.llmConfiguration.summaryAuthMethod == .chatGPT ? services.llmConfiguration.summaryChatGPTModel : services.llmConfiguration.summaryOpenAIModel.title) }
                NavigationLink { chatDefaults } label: { defaultRow("Chat", provider: services.llmConfiguration.chatProvider == .openAI && services.llmConfiguration.chatAuthMethod == .chatGPT ? "ChatGPT" : services.llmConfiguration.chatProvider.title, model: services.llmConfiguration.chatProvider == .gemini ? services.llmConfiguration.chatGeminiModel : services.llmConfiguration.chatAuthMethod == .chatGPT ? services.llmConfiguration.chatChatGPTModel : services.llmConfiguration.chatOpenAIModel.title) }
            } footer: { Text("Connect accounts to make their providers available. Summary and Chat defaults are independent.") }
        }.navigationTitle("AI Defaults").navigationBarTitleDisplayMode(.inline)
    }

    private func defaultRow(_ title: String, provider: String, model: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(defaultDescription(provider: provider, model: model)).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func defaultDescription(provider: String, model: String) -> String {
        if provider == LLMProviderID.mock.title { return provider }
        let name = provider == LLMProviderID.openAI.title ? TranscriptionProviderID.openAI.title : provider
        let title = providerSettings.availableChatGPTModels.first(where: { $0.slug == model })?.displayName
            ?? services.llmResolver.summaryModels(for: .gemini).first(where: { $0.id == model })?.title
            ?? services.transcriptionResolver.models(for: .gemini).first(where: { $0.id == model })?.title
            ?? model
        return name + " · " + title
    }

    // MARK: - OpenAI Configuration

    private var openAISection: some View {
        Section(header: Text("OpenAI Configuration"), footer: Text("Your API key is securely stored in the iOS Keychain and never logged or displayed in plain text.")) {
            HStack {
                Label("Status", systemImage: "key.fill")
                Spacer()
                if providerSettings.keyIsConfigured {
                    Label("Configured", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.callout.weight(.medium))
                } else {
                    Text("Not Configured")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }

            if providerSettings.keyIsConfigured {
                Button("Remove API Key", role: .destructive) {
                    showingRemoveConfirmation = true
                }
                .disabled(providerSettings.isBusy || isOfflineReview)
            } else {
                SecureField("Enter OpenAI API Key (sk-...)", text: $providerSettings.keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.openai.key")

                Button(action: {
                    Task {
                        await providerSettings.saveKey()
                    }
                }) {
                    HStack {
                        Text("Save API Key")
                        if providerSettings.isBusy {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(providerSettings.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || providerSettings.isBusy || isOfflineReview)
                .accessibilityIdentifier("settings.openai.save")
            }

            if let error = providerSettings.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Generation Defaults

    private var summaryDefaults: some View {
        Form {
            Section("Summary") {
            Picker("Summary Provider", selection: Binding<LLMProviderID?>(
                get: { availableLLMProviders.contains(services.llmConfiguration.summaryProvider) ? Optional(services.llmConfiguration.summaryProvider) : nil },
                set: { selection in
                    guard let selection else { return }
                    let newProvider = selection
                    services.llmConfiguration.summaryProvider = newProvider
                    if newProvider == .gemini { services.llmConfiguration.summaryGeminiAuthenticationMethod = .oauth }
                    if newProvider == .openAI, presentedChatGPTAccount?.planUsageEnabled == true { services.llmConfiguration.summaryAuthMethod = .chatGPT }
                }
            )) {
                Text("Choose a connected provider").tag(Optional<LLMProviderID>.none)
                ForEach(availableLLMProviders) { provider in
                    Text(provider.title).tag(Optional(provider))
                }
            }

            if services.llmConfiguration.summaryProvider == .openAI {
                Picker("Summary Access", selection: Binding(get: { services.llmConfiguration.summaryAuthMethod }, set: { services.llmConfiguration.summaryAuthMethod = $0 })) {
                    if providerSettings.keyIsConfigured { Text("OpenAI API").tag(OpenAIAuthenticationMethod.apiKey) }
                    if presentedChatGPTAccount?.planUsageEnabled == true { Text("ChatGPT Plan").tag(OpenAIAuthenticationMethod.chatGPT) }
                }
                if services.llmConfiguration.summaryAuthMethod == .chatGPT {
                    Picker("Summary Model", selection: Binding(get: { services.llmConfiguration.summaryChatGPTModel }, set: { services.llmConfiguration.summaryChatGPTModel = $0 })) {
                        ForEach(providerSettings.availableChatGPTModels) { model in Text(model.displayName).tag(model.slug) }
                    }
                } else {
                    Picker("Summary Model", selection: Binding(get: { services.llmConfiguration.summaryOpenAIModel }, set: { services.llmConfiguration.summaryOpenAIModel = $0 })) {
                        ForEach(OpenAILLMModel.allCases) { model in Text(model.title).tag(model) }
                    }
                }
            }
            if services.llmConfiguration.summaryProvider == .gemini {
                Picker("Summary Model", selection: Binding(get: { services.llmConfiguration.summaryGeminiModel }, set: { services.llmConfiguration.summaryGeminiModel = $0 })) {
                    Text("Gemini 3.8 Flash").tag("gemini-3.8-flash")
                }
            }

            }
        }.navigationTitle("Summary Defaults").navigationBarTitleDisplayMode(.inline)
    }

    private var chatDefaults: some View {
        Form {
            Section("Chat") {
            Picker("Chat Provider", selection: Binding<LLMProviderID?>(
                get: { availableLLMProviders.contains(services.llmConfiguration.chatProvider) ? Optional(services.llmConfiguration.chatProvider) : nil },
                set: { selection in
                    guard let newProvider = selection else { return }
                    services.llmConfiguration.chatProvider = newProvider
                    if newProvider == .gemini { services.llmConfiguration.chatGeminiAuthenticationMethod = .oauth }
                    if newProvider == .openAI, presentedChatGPTAccount?.planUsageEnabled == true { services.llmConfiguration.chatAuthMethod = .chatGPT }
                }
            )) {
                Text("Choose a connected provider").tag(Optional<LLMProviderID>.none)
                ForEach(availableLLMProviders) { provider in
                    Text(provider.title).tag(Optional(provider))
                }
            }

            if services.llmConfiguration.chatProvider == .openAI {
                Picker("Chat Access", selection: Binding(get: { services.llmConfiguration.chatAuthMethod }, set: { services.llmConfiguration.chatAuthMethod = $0 })) {
                    if providerSettings.keyIsConfigured { Text("OpenAI API").tag(OpenAIAuthenticationMethod.apiKey) }
                    if presentedChatGPTAccount?.planUsageEnabled == true { Text("ChatGPT Plan").tag(OpenAIAuthenticationMethod.chatGPT) }
                }
                if services.llmConfiguration.chatAuthMethod == .chatGPT {
                    Picker("Chat Model", selection: Binding(get: { services.llmConfiguration.chatChatGPTModel }, set: { services.llmConfiguration.chatChatGPTModel = $0 })) {
                        ForEach(providerSettings.availableChatGPTModels) { model in Text(model.displayName).tag(model.slug) }
                    }
                } else {
                    Picker("Chat Model", selection: Binding(get: { services.llmConfiguration.chatOpenAIModel }, set: { services.llmConfiguration.chatOpenAIModel = $0 })) {
                        ForEach(OpenAILLMModel.allCases) { model in Text(model.title).tag(model) }
                    }
                }
            }
            if services.llmConfiguration.chatProvider == .gemini {
                Picker("Chat Model", selection: Binding(get: { services.llmConfiguration.chatGeminiModel }, set: { services.llmConfiguration.chatGeminiModel = $0 })) {
                    Text("Gemini 3.8 Flash").tag("gemini-3.8-flash")
                }
            }

            }
        }.navigationTitle("Chat Defaults").navigationBarTitleDisplayMode(.inline)
    }

    private var transcriptionDefaults: some View {
        Form {
            Section("Transcription") {
            Picker("Transcription Provider", selection: Binding<TranscriptionProviderID?>(
                get: { availableTranscriptionProviders.contains(services.configuration.selectedProvider) ? Optional(services.configuration.selectedProvider) : nil },
                set: { if let provider = $0 { services.configuration.selectedProvider = provider } }
            )) {
                Text("Choose a connected provider").tag(Optional<TranscriptionProviderID>.none)
                ForEach(availableTranscriptionProviders) { provider in
                    Text(provider.title).tag(Optional(provider))
                }
            }

            if services.configuration.selectedProvider == .openAI {
                Picker("Transcription Model", selection: Binding(
                    get: { services.configuration.openAIModel },
                    set: { services.configuration.openAIModel = $0 }
                )) {
                    ForEach(OpenAITranscriptionModel.standardModels) { model in
                        Text(model.title).tag(model)
                    }
                }

                Picker("Audio Language", selection: Binding(
                    get: { services.configuration.language },
                    set: { services.configuration.language = $0 }
                )) {
                    ForEach(TranscriptionLanguage.allCases) { lang in
                        Text(lang.title).tag(lang)
                    }
                }
            }

            if services.configuration.selectedProvider == .gemini {
                Picker("Transcription Model", selection: Binding(
                    get: { services.configuration.geminiModel },
                    set: { services.configuration.geminiModel = $0 }
                )) {
                    Text("Gemini 3.5 Transcribe").tag("gemini-3.5-transcribe")
                }
                Text("Timestamped Gemini transcription supports audio up to 30 minutes. Usage is billed to the configured Google Cloud project.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            }
        }.navigationTitle("Transcription Defaults").navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - About

    private var aboutSection: some View {
        Section(header: Text("About")) {
            HStack {
                Text("Application")
                Spacer()
                Text("AudioNotes").foregroundStyle(.secondary)
            }
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0").foregroundStyle(.secondary)
            }
            HStack {
                Text("Build")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1").foregroundStyle(.secondary)
            }
            HStack {
                Text("Platform Shell")
                Spacer()
                Text("Native iOS & iPadOS").foregroundStyle(.secondary)
            }
        }
    }

    private var availableTranscriptionProviders: [TranscriptionProviderID] {
        IOSProviderAvailability.transcription(openAIKey: providerSettings.keyIsConfigured, geminiConnected: geminiAccount != nil, includeMock: services.configuration.selectedProvider == .mock)
    }

    private var availableLLMProviders: [LLMProviderID] {
        var providers: [LLMProviderID] = []
#if DEBUG
        if services.llmConfiguration.summaryProvider == .mock || services.llmConfiguration.chatProvider == .mock { providers.append(.mock) }
#endif
        if providerSettings.keyIsConfigured || presentedChatGPTAccount?.planUsageEnabled == true { providers.append(.openAI) }
        if geminiAccount != nil { providers.append(.gemini) }
        return providers
    }
}
#endif
