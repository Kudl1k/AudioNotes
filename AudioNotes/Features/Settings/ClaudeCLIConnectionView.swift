import SwiftUI

struct ClaudeCLIConnectionView: View {
    @Bindable var configuration: LLMConfiguration
    @ObservedObject var settings: ProviderSettingsViewModel
    @StateObject private var model = ClaudeCLISettingsViewModel()

    var body: some View {
        Section("Claude Code account") {
            TextField("Claude executable (blank to detect automatically)", text: $configuration.claudeExecutablePath)
                .disabled(model.isBusy || settings.isFetchingClaudeModels)
            if let account = model.account {
                Label(account.state == .connected ? "Connected to Claude Code" : "Claude Code sign-in required",
                      systemImage: account.state == .connected ? "checkmark.circle.fill" : "person.crop.circle")
                if let email = account.email { Text(email).foregroundStyle(.secondary) }
                if account.state == .needsReauthentication {
                    Text("The CLI is using API or cloud-provider credentials. Sign in with a Claude account to use this integration.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Refresh Claude Models") { Task { await settings.fetchClaudeModels() } }
                    .disabled(model.isBusy || settings.isFetchingClaudeModels)
                if settings.isFetchingClaudeModels {
                    ProgressView().controlSize(.small)
                } else if !configuration.cachedClaudeModels.isEmpty {
                    Text("\(configuration.cachedClaudeModels.count) models loaded").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = settings.claudeModelsError {
                InlineErrorLabel(error)
            }
            HStack {
                Button("Sign in with Claude Code…") { model.signIn(path: configuration.claudeExecutablePath) }
                    .disabled(model.isBusy)
                Button("Refresh Connection") { Task { await model.refresh(path: configuration.claudeExecutablePath) } }
                    .disabled(model.isBusy)
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelSignIn() }
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            Text("Uses your installed Claude Code and its existing account login. Claude Code handles credentials and opens your browser when signing in. You can also run claude auth login in Terminal, then refresh here.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Choose Anthropic Claude for summaries or chat in General. Source text is sent to Claude; original files and images stay local. Usage may consume subscription limits or paid usage credits; Soniquill cannot determine the billed amount.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Install Claude Code…", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
        }
        .task { await model.refresh(path: configuration.claudeExecutablePath) }
        .onChange(of: model.account) { _, account in
            if account?.state == .connected { Task { await settings.fetchClaudeModels() } }
        }
    }
}
