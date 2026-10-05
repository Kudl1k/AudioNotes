#if os(iOS)
import SwiftUI

struct IOSSettingsView: View {
    let services: AppServices
    @Environment(\.dismiss) private var dismiss
    @State private var providerSettings: ProviderSettingsViewModel
    @State private var showingRemoveConfirmation = false
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

    var body: some View {
        NavigationStack {
            Form {
                accountsSection

                openAISection

                generationDefaultsSection

                providerStatusSection

                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
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

    private var accountsSection: some View {
        Section("AI Accounts") {
            if let account = chatGPTAuthService.currentAccount {
                Label("ChatGPT connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(account.email ?? "ChatGPT account").font(.callout).foregroundStyle(.secondary)
                Text(account.planUsageEnabled ? "ChatGPT plan usage authorized" : "Signed in; plan usage not authorized")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        Task { try? await chatGPTAuthService.disconnect() }
                    }
                }
            } else {
                Button {
                    Task { isConnectingAccount = true; defer { isConnectingAccount = false }; do { try await chatGPTAuthService.signIn(); await providerSettings.fetchChatGPTModels() } catch { accountError = error.localizedDescription } }
                } label: {
                    Label(isConnectingAccount ? "Connecting…" : "Continue with ChatGPT", systemImage: "sparkles")
                }.disabled(isConnectingAccount)
            }

            if providerSettings.googleOAuthConfigurationError == nil, let geminiAccount {
                Label("Google connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(geminiAccount.email ?? "Google account").font(.callout).foregroundStyle(.secondary)
                Text("Gemini API · Google Cloud project billing").font(.callout).foregroundStyle(.secondary)
                Button("Disconnect", role: .destructive) {
                    Task { try? await services.googleGeminiOAuth.disconnect(); self.geminiAccount = nil }
                }
            } else {
                Button {
                    Task { isConnectingAccount = true; defer { isConnectingAccount = false }; do { geminiAccount = try await services.googleGeminiOAuth.connect() } catch { accountError = error.localizedDescription } }
                } label: {
                    Label("Continue with Google", systemImage: "person.crop.circle")
                }.disabled(isConnectingAccount || providerSettings.googleOAuthConfigurationError != nil)
                if let googleOAuthConfigurationError = providerSettings.googleOAuthConfigurationError {
                    Text(googleOAuthConfigurationError).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let accountError { Text(accountError).font(.caption).foregroundStyle(.red) }
            Text("ChatGPT plan access and Google Gemini API access are separate from audio transcription. OpenAI transcription uses an API key; Gemini API usage is billed to its configured Google Cloud project.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: - OpenAI Configuration

    private var openAISection: some View {
        Section(header: Text("OpenAI Configuration"), footer: Text("Your API key is securely stored in the iOS Keychain and never logged or displayed in plain text.")) {
            HStack {
                Label("Status", systemImage: "key.fill")
                Spacer()
                if providerSettings.keyIsConfigured {
                    Label("Configured", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
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
                .disabled(providerSettings.isBusy)
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
                .disabled(providerSettings.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || providerSettings.isBusy)
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

    private var generationDefaultsSection: some View {
        Section(header: Text("Generation Defaults")) {
            Picker("Summary Provider", selection: Binding(
                get: { services.llmConfiguration.summaryProvider },
                set: {
                    services.llmConfiguration.summaryProvider = $0
                    if $0 == .gemini { services.llmConfiguration.summaryGeminiAuthenticationMethod = .oauth }
                    if $0 == .openAI, services.chatGPTAuthService.currentAccount?.planUsageEnabled == true { services.llmConfiguration.summaryAuthMethod = .chatGPT }
                }
            )) {
                ForEach(LLMProviderID.currentPlatformSelectable) { provider in
                    Text(provider.title).tag(provider)
                }
            }

            if services.llmConfiguration.summaryProvider == .openAI {
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

            Picker("Chat Provider", selection: Binding(
                get: { services.llmConfiguration.chatProvider },
                set: {
                    services.llmConfiguration.chatProvider = $0
                    if $0 == .gemini { services.llmConfiguration.chatGeminiAuthenticationMethod = .oauth }
                    if $0 == .openAI, services.chatGPTAuthService.currentAccount?.planUsageEnabled == true { services.llmConfiguration.chatAuthMethod = .chatGPT }
                }
            )) {
                ForEach(LLMProviderID.currentPlatformSelectable) { provider in
                    Text(provider.title).tag(provider)
                }
            }

            if services.llmConfiguration.chatProvider == .openAI {
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

            Picker("Transcription Provider", selection: Binding(
                get: { services.configuration.selectedProvider },
                set: { services.configuration.selectedProvider = $0 }
            )) {
                ForEach(TranscriptionProviderID.currentPlatformSelectable) { provider in
                    Text(provider.title).tag(provider)
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
    }

    // MARK: - Provider Status

    private var providerStatusSection: some View {
        Section(header: Text("Platform Providers")) {
            providerRow(title: "OpenAI", systemImage: "sparkles", status: providerSettings.keyIsConfigured ? "Ready" : "Key required", available: true)
            providerRow(title: "Anthropic (Claude)", systemImage: "text.bubble", status: "Requires Mac Claude CLI", available: false)
            providerRow(title: "Local Whisper", systemImage: "waveform", status: "Coming in M16.7", available: false)
            providerRow(title: "Ollama (Local AI)", systemImage: "desktopcomputer", status: "Coming in M16.7", available: false)
            providerRow(title: "Google Gemini", systemImage: "star", status: geminiAccount == nil ? "Connect Google account" : "Ready · Cloud billed", available: true)
        }
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

    private func providerRow(title: String, systemImage: String, status: String, available: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(status)
                .font(.callout)
                .foregroundStyle(available ? Color.accentColor : Color.secondary)
        }
    }
}
#endif
