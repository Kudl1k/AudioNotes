import SwiftUI

struct ClaudeCLIConnectionView: View {
    @Bindable var configuration: LLMConfiguration
    @ObservedObject var settings: ProviderSettingsViewModel
    @StateObject private var model = ClaudeCLISettingsViewModel()
    @State private var accountTask: Task<Void, Never>?
    @State private var modelsTask: Task<Void, Never>?

    var body: some View {
        Group {
            accountSection
            modelsSection
            Section {
                DisclosureGroup("Connection Details") {
                    TextField("Claude Executable", text: $configuration.claudeExecutablePath, prompt: Text("Automatic"))
                        .disabled(model.operation != nil || settings.isFetchingClaudeModels)
                    if model.account?.state == .connected {
                        Button("Sign in Again…") { updateAccount(.signingIn) }
                            .disabled(model.operation != nil || settings.isFetchingClaudeModels)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Link("Install Claude Code…", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
#if os(macOS)
                .disclosureGroupStyle(FullWidthDisclosureStyle())
#endif
            }
        }
        .task { updateAccount(.checking) }
        .onDisappear {
            accountTask?.cancel()
            modelsTask?.cancel()
        }
    }

    private var accountSection: some View {
        Section {
            LabeledContent("Status") {
                HStack {
                    if let operation = model.operation {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(operation == .checking ? "Checking connection…" : "Waiting for browser sign-in…")
                    } else {
                        Text(accountStatus)
                    }
                }
            }
            if let email = model.account?.email {
                LabeledContent("Account") { Text(email).textSelection(.enabled) }
            }
            HStack {
                Button("Refresh Connection") { updateAccount(.checking) }
                    .disabled(model.operation != nil)
                if model.account?.state != .connected {
                    Button("Sign in with Claude Code…") { updateAccount(.signingIn) }
                        .disabled(model.operation != nil || settings.isFetchingClaudeModels)
                }
                if let accountTask, model.operation != nil {
                    Button("Cancel") { accountTask.cancel() }
                }
            }
            if let error = model.errorMessage { InlineErrorLabel(error) }
        } header: {
            Text("Claude Code Account")
        } footer: {
            if model.account?.state == .needsReauthentication {
                Text("Sign in with a Claude account to use this integration.")
            } else {
                Text("Your Claude Code account can be used for summaries and chat. Selected source text is sent to Claude.")
            }
        }
    }

    private var modelsSection: some View {
        Section("Models") {
            LabeledContent("Available Models") {
                HStack {
                    if settings.isFetchingClaudeModels {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text("Refreshing…")
                    }
                    if !configuration.cachedClaudeModels.isEmpty {
                        Text(configuration.cachedClaudeModels.count.formatted())
                    } else if !settings.isFetchingClaudeModels {
                        Text("Not Loaded")
                    }
                }
            }
            HStack {
                Button("Refresh Models") { refreshModels(force: true) }
                    .disabled(model.account?.state != .connected || model.operation != nil || settings.isFetchingClaudeModels)
                if let modelsTask, settings.isFetchingClaudeModels {
                    Button("Cancel") { modelsTask.cancel() }
                }
            }
            if let error = settings.claudeModelsError { InlineErrorLabel(error) }
        }
    }

    private var accountStatus: String {
        switch model.account?.state {
        case .connected: model.errorMessage == nil ? "Connected" : "Last Known: Connected"
        case .needsReauthentication: "Sign-in Required"
        case nil: model.errorMessage == nil ? "Not Checked" : "Unavailable"
        default: "Not Connected"
        }
    }

    private func updateAccount(_ operation: ClaudeCLISettingsViewModel.Operation) {
        guard accountTask == nil, model.operation == nil else { return }
        let path = configuration.claudeExecutablePath
        accountTask = Task {
            defer { accountTask = nil }
            switch operation {
            case .checking:
                if await model.refresh(path: path), !Task.isCancelled { refreshModels(force: false) }
            case .signingIn:
                if await model.signIn(path: path), !Task.isCancelled { refreshModels(force: true) }
            }
        }
    }

    private func refreshModels(force: Bool) {
        guard modelsTask == nil, !settings.isFetchingClaudeModels else { return }
        modelsTask = Task {
            defer { modelsTask = nil }
            if force {
                await settings.fetchClaudeModels()
            } else {
                await settings.loadClaudeModelsIfNeeded()
            }
        }
    }
}
