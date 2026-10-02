import SwiftUI

struct ProviderConnectionsView: View {
    @Bindable var llmConfig: LLMConfiguration
    @ObservedObject var model: ProviderSettingsViewModel
    let localAISettings: LocalAISettingsViewModel
    let selectedProvider: ConnectionProvider

    enum ConnectionProvider: String, CaseIterable, Identifiable {
        case openAI = "OpenAI"
        case anthropic = "Anthropic"
        case gemini = "Gemini"
        case local = "Local AI"

        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("Provider connection") {
                Text("Connect accounts and manage API keys here. Choose the provider and model for each feature in General.")
                    .font(.callout).foregroundStyle(.secondary)
            }

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
        .padding(16)
    }

    @ViewBuilder
    private var openAISections: some View {
        Section("OpenAI Credentials") {
            Label(model.status, systemImage: model.keyIsConfigured ? "key.fill" : "key")
            SecureField(model.keyIsConfigured ? "Enter a replacement API key" : "Enter an API key", text: $model.keyInput)
                .autocorrectionDisabled()
                .disabled(model.isBusy)
            HStack {
                Button(model.keyIsConfigured ? "Update Key" : "Save Key") {
                    Task { await model.saveKey() }
                }
                .disabled(model.isBusy || model.keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Remove Key", role: .destructive) {
                    Task { await model.removeKey() }
                }
                .disabled(model.isBusy || !model.keyIsConfigured)

                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            Text("Stored securely in macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("ChatGPT Account (Sign in with ChatGPT)") {
            if let account = model.chatGPTAccount {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email ?? account.displayName ?? "Connected Account")
                                .font(.headline)
                            Text("Client: \(account.issuedClientID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if account.planUsageEnabled {
                        Label("ChatGPT Plan Usage: Active", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    } else {
                        Label("Plan Permission Not Granted", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    }
                }
                .padding(.vertical, 4)

                HStack {
                    if let usageURL = URL(string: "https://chatgpt.com/settings/usage") {
                        Link("Check Usage", destination: usageURL)
                    }
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        Task { await model.disconnectChatGPT() }
                    }
                    .disabled(model.chatGPTIsBusy)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect your ChatGPT subscription (Plus/Team/Pro) to generate summaries and chat without API billing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button {
                            Task { await model.signInWithChatGPT() }
                        } label: {
                            if model.chatGPTIsBusy {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Connecting in browser…")
                                }
                            } else {
                                Label("Sign in with ChatGPT", systemImage: "arrow.up.right.square")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.chatGPTIsBusy)
                    }

                    if let err = model.chatGPTErrorMessage {
                        InlineErrorLabel(err)
                    }
                }
                .padding(.vertical, 4)
            }
        }
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

    private var geminiSection: some View {
        Section("Google Gemini API") {
            if let error = model.googleOAuthConfigurationError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if model.googleOAuthIsConfigured {
                Label("Google sign-in configured by the app", systemImage: "checkmark.circle")
            }
            if let account = model.googleAccount {
                Label(account.email.map { "Connected with Google · \($0)" } ?? "Connected with Google", systemImage: "person.crop.circle.fill")
                Button("Disconnect Google", role: .destructive) { Task { await model.disconnectGoogle() } }
                    .disabled(model.googleOAuthIsBusy)
            } else {
                Button {
                    Task { await model.connectGoogle() }
                } label: {
                    if model.googleOAuthIsBusy { ProgressView().controlSize(.small) }
                    else { Label("Sign in with Google", systemImage: "person.crop.circle") }
                }
                .disabled(model.googleOAuthIsBusy || !model.googleOAuthIsConfigured)
            }
            Text("Google OAuth authorizes Gemini API access for the configured Google Cloud project. It does not imply that a consumer Gemini subscription pays for API use.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.googleOAuthError { InlineErrorLabel(error) }
            Label(model.geminiKeyIsConfigured ? "API key configured" : "No API key configured",
                  systemImage: model.geminiKeyIsConfigured ? "key.fill" : "key")
            SecureField(model.geminiKeyIsConfigured ? "Enter a replacement Gemini API key" : "Enter a Gemini API key",
                        text: $model.geminiKeyInput)
                .autocorrectionDisabled()
                .disabled(model.isBusy)
            HStack {
                Button(model.geminiKeyIsConfigured ? "Update Key" : "Save Key") {
                    Task { await model.saveProviderKey(.gemini) }
                }
                .disabled(model.isBusy || model.geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove Key", role: .destructive) {
                    Task { await model.removeProviderKey(.gemini) }
                }
                .disabled(model.isBusy || !model.geminiKeyIsConfigured)
            }
            Text("Use a Gemini API key from Google AI Studio. This credential is independent from Google OAuth; neither method implies consumer Gemini subscription billing.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Get a Gemini API key…", destination: URL(string: "https://ai.google.dev/gemini-api/docs/api-key")!)
        }
    }
}
