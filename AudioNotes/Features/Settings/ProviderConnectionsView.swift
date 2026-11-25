import SwiftUI

struct ProviderConnectionsView: View {
    @Bindable var llmConfig: LLMConfiguration
    @ObservedObject var model: ProviderSettingsViewModel
    let localAISettings: LocalAISettingsViewModel
    let selectedProvider: ConnectionProvider
    @State private var keyEditorProvider: ConnectionProvider?
    @State private var confirmsKeyRemoval = false
    @State private var confirmsChatGPTDisconnect = false
    @State private var confirmsGoogleDisconnect = false
    @State private var confirmsGeminiKeyRemoval = false

    enum ConnectionProvider: String, CaseIterable, Identifiable {
        case openAI = "OpenAI"
        case anthropic = "Claude"
        case gemini = "Google / Gemini"
        case local = "Local AI"

        var id: String { rawValue }
    }

    var body: some View {
        Form {
            switch selectedProvider {
            case .openAI: openAISections
            case .anthropic: anthropicSection
            case .gemini: geminiSection
            case .local:
                LocalAISettingsView(model: localAISettings)
            }

            if selectedProvider != .local, let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $keyEditorProvider, onDismiss: {
            model.keyInput = ""
            model.geminiKeyInput = ""
        }, content: keyEditor)
        .confirmationDialog("Disconnect Google?", isPresented: $confirmsGoogleDisconnect, titleVisibility: .visible) {
            Button("Disconnect Google", role: .destructive) { Task { await model.disconnectGoogle() } }
        }
        .confirmationDialog("Remove Gemini API Key?", isPresented: $confirmsGeminiKeyRemoval, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) { Task { await model.removeProviderKey(.gemini) } }
        }
        .confirmationDialog("Remove OpenAI API Key?", isPresented: $confirmsKeyRemoval, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) { Task { await model.removeKey() } }
        } message: {
            Text("Features using OpenAI API billing will need a new key.")
        }
        .confirmationDialog("Disconnect ChatGPT?", isPresented: $confirmsChatGPTDisconnect, titleVisibility: .visible) {
            Button("Disconnect ChatGPT", role: .destructive) { Task { await model.disconnectChatGPT() } }
        } message: {
            Text("Summaries and chat that use the ChatGPT plan will need you to sign in again.")
        }
    }

    @ViewBuilder
    private var openAISections: some View {
        Section {
            if let account = model.chatGPTAccount {
                LabeledContent("Status", value: "Connected")
                LabeledContent("Account") {
                    Text(account.email ?? account.displayName ?? "ChatGPT account")
                        .textSelection(.enabled)
                }
                LabeledContent("Plan Access", value: account.planUsageEnabled ? "Authorized" : "Not Authorized")
                Link(AccountUsageProvider.chatGPT.dashboardTitle, destination: AccountUsageProvider.chatGPT.dashboardURL)
                Button("Disconnect ChatGPT…", role: .destructive) { confirmsChatGPTDisconnect = true }
                    .disabled(model.chatGPTIsBusy)
            } else if model.chatGPTIsBusy {
                ProgressView("Connecting in browser…").controlSize(.small)
            } else {
                LabeledContent("Status", value: "Not Connected")
                Button("Sign in with ChatGPT") {
                    Task { await model.signInWithChatGPT() }
                }
            }
            if let error = model.chatGPTErrorMessage { InlineErrorLabel(error) }
        } header: {
            Text("ChatGPT Account")
        } footer: {
            Text("Use your ChatGPT plan for summaries and chat.")
        }

        Section {
            LabeledContent("Status", value: model.keyIsConfigured ? "Configured" : "Not Configured")
            Button(model.keyIsConfigured ? "Replace API Key…" : "Add API Key…") {
                model.keyInput = ""
                keyEditorProvider = .openAI
            }
            .disabled(model.isBusy)
            if model.keyIsConfigured {
                Button("Remove Key…", role: .destructive) { confirmsKeyRemoval = true }
                    .disabled(model.isBusy)
            }
        } header: {
            Text("OpenAI API Key")
        } footer: {
            Text("Enables transcription, summaries, and chat with OpenAI API billing.")
        }
    }

    private func keyEditor(for provider: ConnectionProvider) -> some View {
        let isGemini = provider == .gemini
        let configured = isGemini ? model.geminiKeyIsConfigured : model.keyIsConfigured
        let input = isGemini ? $model.geminiKeyInput : $model.keyInput
        let providerName = isGemini ? "Gemini" : "OpenAI"
        let canSave = !model.isBusy && !input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let save: () -> Void = {
            Task { @MainActor in
                if isGemini {
                    await model.saveProviderKey(.gemini)
                } else {
                    await model.saveKey()
                }
                if model.errorMessage == nil { keyEditorProvider = nil }
            }
        }

        return Form {
            Section {
                SecureField("API Key", text: input)
                    .autocorrectionDisabled()
                    .disabled(model.isBusy)
                    .onSubmit { if canSave { save() } }
                if let error = model.errorMessage { InlineErrorLabel(error) }
            } header: {
                Text(configured ? "Replace \(providerName) API Key" : "Add \(providerName) API Key")
            } footer: {
                Text("Your key is stored in Keychain.")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { keyEditorProvider = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isBusy)
                Button("Save Key") { if canSave { save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380)
        .interactiveDismissDisabled(model.isBusy)
    }

    private var anthropicSection: some View {
        Group {
#if os(macOS)
            if PlatformCapabilities.current.supportsClaudeCLI {
                ClaudeCLIConnectionView(configuration: llmConfig, settings: model)
            } else {
                Section("Anthropic Claude") {
                    Text("Claude CLI is unavailable on this system.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
#else
            Section("Anthropic Claude") {
                Text("Claude Code CLI integration is available on macOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
#endif
            if model.anthropicKeyIsConfigured {
                Section("Previously saved API key") {
                    Text("Claude Code uses its account login. This saved API key is not used for summaries or chat.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Remove Saved Key", role: .destructive) {
                        Task { await model.removeProviderKey(.anthropic) }
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private var geminiSection: some View {
        Section {
            if let account = model.googleAccount {
                LabeledContent("Status", value: "Connected")
                LabeledContent("Account") {
                    Text(account.email ?? "Google account").textSelection(.enabled)
                }
                Link(AccountUsageProvider.gemini.dashboardTitle, destination: AccountUsageProvider.gemini.dashboardURL)
                Button("Disconnect Google…", role: .destructive) { confirmsGoogleDisconnect = true }
                    .disabled(model.googleOAuthIsBusy)
            } else if model.googleOAuthIsBusy {
                ProgressView("Connecting in browser…").controlSize(.small)
            } else {
                LabeledContent("Status", value: "Not Connected")
                Button("Sign in with Google") { Task { await model.connectGoogle() } }
                    .disabled(!model.googleOAuthIsConfigured)
                if let error = model.googleOAuthConfigurationError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.googleOAuthError { InlineErrorLabel(error) }
        } header: {
            Text("Google Account")
        } footer: {
            Text("Google sign-in authorizes Gemini API access billed to the configured Google Cloud project.")
        }

        Section {
            LabeledContent("Status", value: model.geminiKeyIsConfigured ? "Configured" : "Not Configured")
            Button(model.geminiKeyIsConfigured ? "Replace API Key…" : "Add API Key…") {
                model.geminiKeyInput = ""
                keyEditorProvider = .gemini
            }
            .disabled(model.isBusy)
            if model.geminiKeyIsConfigured {
                Button("Remove Key…", role: .destructive) { confirmsGeminiKeyRemoval = true }
                    .disabled(model.isBusy)
            }
            Link("Get a Gemini API key…", destination: URL(string: "https://ai.google.dev/gemini-api/docs/api-key")!)
        } header: {
            Text("Gemini API Key")
        } footer: {
            Text("Uses Gemini API billing with a key from Google AI Studio.")
        }
    }
}
