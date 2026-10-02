import Foundation
import Combine

@MainActor
final class ProviderSettingsViewModel: ObservableObject {
    @Published var keyInput: String = ""
    @Published var anthropicKeyInput: String = ""
    @Published var geminiKeyInput: String = ""
    @Published private(set) var keyIsConfigured: Bool = false
    @Published private(set) var anthropicKeyIsConfigured: Bool = false
    @Published private(set) var geminiKeyIsConfigured: Bool = false
    @Published private(set) var status: String = "Checking Keychain…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy: Bool = false

    // ChatGPT Account Auth
    @Published private(set) var chatGPTAuthState: ChatGPTAuthState = .signedOut
    @Published private(set) var chatGPTErrorMessage: String?
    @Published private(set) var chatGPTIsBusy: Bool = false

    @Published private(set) var googleAccount: ProviderAccount?
    @Published private(set) var googleOAuthIsBusy: Bool = false
    @Published private(set) var googleOAuthError: String?
    @Published private(set) var googleOAuthConfigurationError: String?
    @Published private(set) var googleOAuthIsConfigured = false

    // Dynamic model fetching
    @Published private(set) var isFetchingClaudeModels = false
    @Published private(set) var claudeModelsError: String?
    private var claudeModelsAttemptedPath: String?
    @Published private(set) var isFetchingChatGPTModels: Bool = false
    @Published private(set) var chatGPTModelsError: String?
    @Published var availableChatGPTModels: [OpenAIModelItem] = []

    @Published private(set) var isFetchingTranscriptionModels: Bool = false
    @Published private(set) var transcriptionModelsError: String?
    @Published var availableTranscriptionModels: [OpenAITranscriptionModel] = []

    // Debug logs
    @Published var copiedLogsNotice: Bool = false

    private let credentials: any CredentialStoring
    private let transcriptionConfig: TranscriptionConfiguration?
    private let llmConfig: LLMConfiguration?
    private let chatGPTAuth: (any ChatGPTAuthenticating)?
    private let tokenRefresher: (any ChatGPTTokenRefreshing)?
    private let modelsClient: any OpenAIModelsFetching
    private let googleOAuth: GoogleGeminiOAuthService?
    private let claudeModelsClient: any ClaudeCLIModelsFetching

    init(
        credentials: any CredentialStoring,
        chatGPTAuth: (any ChatGPTAuthenticating)? = nil,
        tokenRefresher: (any ChatGPTTokenRefreshing)? = nil,
        modelsClient: any OpenAIModelsFetching = OpenAIModelsClient(),
        transcriptionConfig: TranscriptionConfiguration? = nil,
        llmConfig: LLMConfiguration? = nil,
        googleOAuth: GoogleGeminiOAuthService? = nil,
        claudeModelsClient: any ClaudeCLIModelsFetching = ClaudeCLIModelsClient()
    ) {
        self.credentials = credentials
        self.chatGPTAuth = chatGPTAuth
        self.tokenRefresher = tokenRefresher
        self.modelsClient = modelsClient
        self.transcriptionConfig = transcriptionConfig
        self.llmConfig = llmConfig
        self.googleOAuth = googleOAuth
        self.claudeModelsClient = claudeModelsClient

        self.chatGPTAuthState = chatGPTAuth?.authState ?? .signedOut

        if let cached = llmConfig?.cachedChatGPTModels, !cached.isEmpty {
            self.availableChatGPTModels = cached
        } else {
            self.availableChatGPTModels = [
                OpenAIModelItem(slug: "gpt-4o", displayName: "GPT-4o (flagship)"),
                OpenAIModelItem(slug: "o3-mini", displayName: "o3-mini (reasoning)")
            ]
        }

        if let cachedVoice = transcriptionConfig?.availableVoiceModels, !cachedVoice.isEmpty {
            self.availableTranscriptionModels = cachedVoice
        } else {
            self.availableTranscriptionModels = OpenAITranscriptionModel.standardModels
        }
    }

    var isChatGPTSignedIn: Bool {
        if case .signedIn = chatGPTAuthState { return true }
        return false
    }

    var chatGPTAccount: ChatGPTAccount? {
        if case .signedIn(let account) = chatGPTAuthState { return account }
        return nil
    }

    var chatGPTEmail: String? {
        chatGPTAccount?.email
    }

    var isChatGPTPlanUsageEnabled: Bool {
        chatGPTAccount?.planUsageEnabled ?? false
    }

    var logsAreEmpty: Bool {
        DebugLogService.shared.isEmpty
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            keyIsConfigured = try await credentials.containsKey(for: .openAI)
            async let hasAnthropicKey = credentials.containsKey(for: .anthropic)
            async let hasGeminiKey = credentials.containsKey(for: .gemini)
            anthropicKeyIsConfigured = try await hasAnthropicKey
            geminiKeyIsConfigured = try await hasGeminiKey
            status = keyIsConfigured ? "API key configured" : "No API key configured"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            status = "Keychain status unavailable"
        }

        if let chatGPTAuth {
            await chatGPTAuth.restoreSession()
            chatGPTAuthState = chatGPTAuth.authState
        }
        if let googleOAuth {
            googleAccount = await googleOAuth.account()
            googleOAuthConfigurationError = await googleOAuth.configurationStatus()
            googleOAuthIsConfigured = googleOAuthConfigurationError == nil
        }
    }

    func connectGoogle() async {
        guard let googleOAuth else { return }
        googleOAuthIsBusy = true
        googleOAuthError = nil
        defer { googleOAuthIsBusy = false }
        do { googleAccount = try await googleOAuth.connect() }
        catch { googleOAuthError = error.localizedDescription }
    }

    func loadClaudeModelsIfNeeded() async {
        guard let llmConfig, claudeModelsAttemptedPath != llmConfig.claudeExecutablePath else { return }
        await fetchClaudeModels()
    }

    func fetchClaudeModels() async {
        guard let llmConfig, !isFetchingClaudeModels else { return }
        let path = llmConfig.claudeExecutablePath
        claudeModelsAttemptedPath = path
        isFetchingClaudeModels = true
        claudeModelsError = nil
        defer { isFetchingClaudeModels = false }
        do {
            let models = try await claudeModelsClient.fetchModels(executable: path)
            try Task.checkCancellation()
            guard llmConfig.claudeExecutablePath == path else { return }
            guard !models.isEmpty else { throw ClaudeCLIError.invalidResponse }
            llmConfig.cachedClaudeModels = models
        } catch is CancellationError {
            claudeModelsAttemptedPath = nil
        } catch {
            if llmConfig.claudeExecutablePath == path { claudeModelsError = error.localizedDescription }
        }
    }

    func disconnectGoogle() async {
        guard let googleOAuth else { return }
        googleOAuthIsBusy = true
        googleOAuthError = nil
        defer { googleOAuthIsBusy = false }
        do { try await googleOAuth.disconnect(); googleAccount = nil }
        catch { googleOAuthError = error.localizedDescription }
    }

    func saveProviderKey(_ account: CredentialAccount) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let raw = account == .anthropic ? anthropicKeyInput : geminiKeyInput
            try await credentials.saveAPIKey(APIKeyInput.normalized(raw), for: account)
            if account == .anthropic { anthropicKeyInput = ""; anthropicKeyIsConfigured = true }
            if account == .gemini { geminiKeyInput = ""; geminiKeyIsConfigured = true }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func removeProviderKey(_ account: CredentialAccount) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await credentials.deleteAPIKey(for: account)
            if account == .anthropic { anthropicKeyInput = ""; anthropicKeyIsConfigured = false }
            if account == .gemini { geminiKeyInput = ""; geminiKeyIsConfigured = false }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func saveKey() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let key = try APIKeyInput.normalized(keyInput)
            try await credentials.saveAPIKey(key, for: .openAI)
            keyInput = ""
            keyIsConfigured = true
            status = "API key configured"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeKey() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await credentials.deleteAPIKey(for: .openAI)
            keyInput = ""
            keyIsConfigured = false
            status = "No API key configured"
            errorMessage = nil
            availableTranscriptionModels = OpenAITranscriptionModel.standardModels
            transcriptionConfig?.availableVoiceModels = OpenAITranscriptionModel.standardModels
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func fetchChatGPTModels() async {
        guard let tokenRefresher else { return }
        guard isChatGPTSignedIn else { return }
        guard !isFetchingChatGPTModels else { return }

        isFetchingChatGPTModels = true
        chatGPTModelsError = nil
        defer { isFetchingChatGPTModels = false }

        do {
            let token = try await tokenRefresher.validAccessToken()
            let all = try await modelsClient.fetchModels(bearerToken: token)
            let filtered = all.filter { item in
                let isAllowed = item.slug != "gpt-4o-mini"
                if let vis = item.visibility {
                    return vis == "list" && isAllowed
                }
                return isAllowed && !item.slug.isEmpty
            }

            if !filtered.isEmpty {
                availableChatGPTModels = filtered
                llmConfig?.cachedChatGPTModels = filtered
                if let current = llmConfig?.chatGPTModel,
                   !filtered.contains(where: { $0.slug == current }) {
                    llmConfig?.chatGPTModel = filtered.first?.slug ?? "gpt-4o"
                }
            }
        } catch {
            chatGPTModelsError = error.localizedDescription
            DebugLogService.shared.error(
                subsystem: "ProviderSettingsViewModel",
                message: "Failed to fetch ChatGPT models: \(error)"
            )
        }
    }

    func fetchVoiceModels() async {
        guard !isFetchingTranscriptionModels else { return }
        isFetchingTranscriptionModels = true
        transcriptionModelsError = nil
        defer { isFetchingTranscriptionModels = false }

        do {
            guard let key = try await credentials.apiKey(for: .openAI), !key.isEmpty else {
                return
            }
            let normalizedKey = try APIKeyInput.normalized(key)
            let all = try await modelsClient.fetchModels(bearerToken: normalizedKey)
            let voiceKeywords = ["whisper", "transcribe"]
            let matched = all.filter { item in
                let name = item.id.lowercased()
                return voiceKeywords.contains { name.contains($0) }
            }

            var models: [OpenAITranscriptionModel] = []
            for item in matched {
                let m = OpenAITranscriptionModel(rawValue: item.id)
                if !models.contains(m) {
                    models.append(m)
                }
            }

            // Ensure standard models are included if not present
            for std in OpenAITranscriptionModel.standardModels {
                if !models.contains(std) {
                    models.append(std)
                }
            }

            // Sort models: whisper-1 first, then gpt-4o-transcribe, then others
            models.sort { lhs, rhs in
                if lhs == .whisper1 { return true }
                if rhs == .whisper1 { return false }
                return lhs.rawValue < rhs.rawValue
            }

            availableTranscriptionModels = models
            transcriptionConfig?.availableVoiceModels = models

            if let current = transcriptionConfig?.openAIModel, !models.contains(current) {
                transcriptionConfig?.openAIModel = .whisper1
            }
        } catch {
            transcriptionModelsError = error.localizedDescription
            DebugLogService.shared.error(
                subsystem: "ProviderSettingsViewModel",
                message: "Failed to fetch voice models: \(error)"
            )
        }
    }

    func signInWithChatGPT() async {
        guard let chatGPTAuth, !chatGPTIsBusy else { return }
        chatGPTIsBusy = true
        chatGPTErrorMessage = nil
        defer { chatGPTIsBusy = false }

        do {
            try await chatGPTAuth.signIn()
            chatGPTAuthState = chatGPTAuth.authState
            if isChatGPTSignedIn {
                await fetchChatGPTModels()
            }
        } catch {
            chatGPTErrorMessage = error.localizedDescription
            chatGPTAuthState = chatGPTAuth.authState
        }
    }

    func disconnectChatGPT() async {
        guard let chatGPTAuth, !chatGPTIsBusy else { return }
        chatGPTIsBusy = true
        chatGPTErrorMessage = nil
        defer { chatGPTIsBusy = false }

        do {
            try await chatGPTAuth.disconnect()
            chatGPTAuthState = .signedOut
            availableChatGPTModels = llmConfig?.cachedChatGPTModels ?? [
                OpenAIModelItem(slug: "gpt-4o", displayName: "GPT-4o (flagship)"),
                OpenAIModelItem(slug: "o3-mini", displayName: "o3-mini (reasoning)")
            ]
        } catch {
            chatGPTErrorMessage = error.localizedDescription
            chatGPTAuthState = chatGPTAuth.authState
        }
    }

    func copyLogs() {
        Clipboard.copy(DebugLogService.shared.formattedLogs())
        copiedLogsNotice = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.copiedLogsNotice = false
        }
    }

    func clearLogs() {
        DebugLogService.shared.clear()
    }
}
