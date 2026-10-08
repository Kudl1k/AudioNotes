import Foundation
import Testing
@testable import AudioNotes

@MainActor
struct ChatGPTAuthTests {

    @Test func planCapabilitiesHideUnsupportedSamplingFieldsWithoutDiscardingPresets() {
        let suite = "ChatGPTPlanCapabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = LLMConfiguration(defaults: defaults)
        configuration.summaryProvider = .openAI
        configuration.chatProvider = .openAI
        configuration.summaryAuthMethod = .chatGPT
        configuration.chatAuthMethod = .chatGPT
        configuration.summarySettings = LLMGenerationSettings(maxOutputTokens: 800, temperature: 0.2, topP: 0.8)
        configuration.chatSettings = LLMGenerationSettings(maxOutputTokens: 900, temperature: 0.4, topP: 0.7)
        #expect(!configuration.summaryCapabilities.supportsTemperature)
        #expect(!configuration.summaryCapabilities.supportsTopP)
        #expect(!configuration.summaryCapabilities.supportsMaxOutputTokens)
        #expect(!configuration.chatCapabilities.supportsTemperature)
        #expect(!configuration.chatCapabilities.supportsTopP)
        #expect(!configuration.chatCapabilities.supportsMaxOutputTokens)
        #expect(configuration.summarySettings.temperature == 0.2)
        #expect(configuration.summarySettings.topP == 0.8)
        #expect(configuration.summarySettings.maxOutputTokens == 800)
        configuration.summaryAuthMethod = .apiKey
        configuration.chatAuthMethod = .apiKey
        #expect(configuration.summaryCapabilities.supportsTemperature)
        #expect(configuration.summarySettings.temperature == 0.2)
    }

    // MARK: - PKCE Helper & Cryptography Tests

    @Test func pkceMatchesRFC7636Vector() throws {
        // RFC 7636 Appendix B Test Vector
        let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expectedChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

        let generatedChallenge = PKCEHelper.generateCodeChallenge(from: rfcVerifier)
        #expect(generatedChallenge == expectedChallenge)
    }

    @Test func pkceCodeVerifierLengthAndCharacters() throws {
        let verifier = try PKCEHelper.generateCodeVerifier()
        #expect(verifier.count >= 43)
        #expect(verifier.count <= 128)

        // RFC 7636 Section 4.1 unreserved characters: [A-Z] / [a-z] / [0-9] / "-" / "." / "_" / "~"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let verifierCharacters = CharacterSet(charactersIn: verifier)
        #expect(allowed.isSuperset(of: verifierCharacters))
    }

    @Test func base64URLRoundTrip() throws {
        let sample = "Hello, Sign In with ChatGPT! \u{1F511} 12345"
        let data = Data(sample.utf8)

        let encoded = PKCEHelper.base64URLEncode(data)
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))

        let decoded = PKCEHelper.base64URLDecode(encoded)
        #expect(decoded != nil)
        #expect(String(data: decoded!, encoding: .utf8) == sample)
    }

    // MARK: - Host Manager Tests

    @Test func hostManagerGeneratesAndPersistsStableHostID() {
        let defaultsSuite = "cz.kudladev.test.hostmanager.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let id1 = ChatGPTHostManager.hostID(defaults: defaults)
        let id2 = ChatGPTHostManager.hostID(defaults: defaults)

        #expect(id1.hasPrefix("urn:uuid:"))
        #expect(id1 == id2)

        let rawUUID = String(id1.dropFirst("urn:uuid:".count))
        #expect(UUID(uuidString: rawUUID) != nil)
    }

    // MARK: - ChatGPT Account & Scope Tests

    @Test func accountDetectsPlanUsageScope() {
        let responseWithPlan = ChatGPTTokenResponse(
            accessToken: "token_123",
            tokenType: "Bearer",
            expiresIn: 3600,
            refreshToken: "refresh_123",
            idToken: nil,
            scope: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
        )
        #expect(responseWithPlan.hasPlanUsageScope == true)

        let responseWithoutPlan = ChatGPTTokenResponse(
            accessToken: "token_123",
            tokenType: "Bearer",
            expiresIn: 3600,
            refreshToken: "refresh_123",
            idToken: nil,
            scope: "openid profile email offline_access resource.invoke"
        )
        #expect(responseWithoutPlan.hasPlanUsageScope == false)
    }

    // MARK: - Token Validation & Claims Tests

    @Test func tokenValidatorRejectsIssuerMismatch() async {
        let validator = ChatGPTIDTokenValidator(expectedIssuer: "https://auth.openai.com")

        // Construct fake JWT with wrong issuer
        let header = PKCEHelper.base64URLEncode(Data(#"{"alg":"RS256","kid":"key1"}"#.utf8))
        let payload = PKCEHelper.base64URLEncode(Data(#"{"iss":"https://evil.com","aud":"client1","sub":"user1","exp":9999999999,"nonce":"nonce1"}"#.utf8))
        let signature = PKCEHelper.base64URLEncode(Data("sig".utf8))
        let jwt = "\(header).\(payload).\(signature)"

        do {
            _ = try await validator.validate(idToken: jwt, expectedNonce: "nonce1", expectedAudience: "client1")
            Issue.record("Expected issuer mismatch error")
        } catch let err as TokenValidationError {
            #expect(err == .issuerMismatch(expected: "https://auth.openai.com", got: "https://evil.com"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func tokenValidatorRejectsAudienceMismatch() async {
        let validator = ChatGPTIDTokenValidator(expectedIssuer: "https://auth.openai.com")

        let header = PKCEHelper.base64URLEncode(Data(#"{"alg":"RS256","kid":"key1"}"#.utf8))
        let payload = PKCEHelper.base64URLEncode(Data(#"{"iss":"https://auth.openai.com","aud":"wrong_client","sub":"user1","exp":9999999999,"nonce":"nonce1"}"#.utf8))
        let signature = PKCEHelper.base64URLEncode(Data("sig".utf8))
        let jwt = "\(header).\(payload).\(signature)"

        do {
            _ = try await validator.validate(idToken: jwt, expectedNonce: "nonce1", expectedAudience: "expected_client")
            Issue.record("Expected audience mismatch error")
        } catch let err as TokenValidationError {
            #expect(err == .audienceMismatch(expected: "expected_client", got: "wrong_client"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func tokenValidatorRejectsNonceMismatch() async {
        let validator = ChatGPTIDTokenValidator(expectedIssuer: "https://auth.openai.com")

        let header = PKCEHelper.base64URLEncode(Data(#"{"alg":"RS256","kid":"key1"}"#.utf8))
        let payload = PKCEHelper.base64URLEncode(Data(#"{"iss":"https://auth.openai.com","aud":"client1","sub":"user1","exp":9999999999,"nonce":"nonce_old"}"#.utf8))
        let signature = PKCEHelper.base64URLEncode(Data("sig".utf8))
        let jwt = "\(header).\(payload).\(signature)"

        do {
            _ = try await validator.validate(idToken: jwt, expectedNonce: "nonce_fresh", expectedAudience: "client1")
            Issue.record("Expected nonce mismatch error")
        } catch let err as TokenValidationError {
            #expect(err == .nonceMismatch(expected: "nonce_fresh", got: "nonce_old"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func tokenValidatorRejectsExpiredToken() async {
        let validator = ChatGPTIDTokenValidator(expectedIssuer: "https://auth.openai.com")

        let header = PKCEHelper.base64URLEncode(Data(#"{"alg":"RS256","kid":"key1"}"#.utf8))
        let pastExp: TimeInterval = 1000
        let payload = PKCEHelper.base64URLEncode(Data("{\"iss\":\"https://auth.openai.com\",\"aud\":\"client1\",\"sub\":\"user1\",\"exp\":\(pastExp),\"nonce\":\"n1\"}".utf8))
        let signature = PKCEHelper.base64URLEncode(Data("sig".utf8))
        let jwt = "\(header).\(payload).\(signature)"

        do {
            _ = try await validator.validate(idToken: jwt, expectedNonce: "n1", expectedAudience: "client1")
            Issue.record("Expected token expired error")
        } catch let err as TokenValidationError {
            #expect(err == .tokenExpired(expiredAt: Date(timeIntervalSince1970: pastExp)))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func idTokenClaimsParsesArrayAudienceAndNamespacedClaims() throws {
        let json = """
        {
            "iss": "https://auth.openai.com",
            "aud": ["https://api.openai.com/v1", "oaiapp_custom123"],
            "sub": "user_openai_456",
            "exp": 1740003600,
            "iat": 1740000000,
            "email": "person@example.com",
            "name": "Jane Developer",
            "https://api.openai.com/auth": {
                "chatgpt_user_id": "user_openai_456",
                "chatgpt_plan_type": "plus"
            }
        }
        """

        let claims = try IDTokenClaims.parseClaims(from: Data(json.utf8))
        #expect(claims.iss == "https://auth.openai.com")
        #expect(claims.sub == "user_openai_456")
        #expect(claims.aud.matches("oaiapp_custom123"))
        #expect(claims.aud.matches("https://api.openai.com/v1"))
        #expect(claims.aud.matches("oaiapp_other") == false)
        #expect(claims.email == "person@example.com")
        #expect(claims.name == "Jane Developer")
        #expect(claims.chatgptPlanType == "plus")
    }

    @Test func idTokenClaimsParsesDynamicClientTransition() throws {
        let json = """
        {
            "iss": "https://auth.openai.com",
            "aud": "dynamic_agent_client",
            "sub": "user_openai_789"
        }
        """

        let claims = try IDTokenClaims.parseClaims(from: Data(json.utf8))
        #expect(claims.aud.matches("oaiapp_issued_later"))
    }

    // MARK: - Token Refresher Tests

    @Test func tokenRefresherReturnsExistingValidTokenWithoutNetwork() async throws {
        let mockStore = MockChatGPTCredentialStore()
        try await mockStore.saveTokens(accessToken: "valid_token_xyz", refreshToken: "refresh_123", idToken: nil)

        let activeAccount = ChatGPTAccount(
            id: "user_1",
            email: "user@example.com",
            displayName: "Test User",
            issuedClientID: "oaiapp_123",
            grantedScopes: ["openid", "chatgpt.tokens.use.direct"],
            planUsageEnabled: true,
            expiresAt: Date().addingTimeInterval(3600)
        )
        let sessionStore = MockChatGPTSessionStore(account: activeAccount)

        let refresher = ChatGPTTokenRefresher(
            credentialStore: mockStore,
            sessionStore: sessionStore
        )

        let token = try await refresher.validAccessToken()
        #expect(token == "valid_token_xyz")
    }

    @Test func tokenRefresherHonorsEarliestRefreshAt() async throws {
        let store = MockChatGPTCredentialStore()
        try await store.saveTokens(accessToken: "still_valid", refreshToken: "refresh_later", idToken: nil)
        let account = ChatGPTAccount(id: "user_1", issuedClientID: "oaiapp_123",
            grantedScopes: ["chatgpt.tokens.use.direct"], planUsageEnabled: true,
            expiresAt: Date().addingTimeInterval(20), earliestRefreshAt: Date().addingTimeInterval(600))
        let fixture = OpenAINetworkFixture(data: Data())
        defer { fixture.cleanUp() }
        let refresher = ChatGPTTokenRefresher(credentialStore: store, urlSession: fixture.session,
            sessionStore: MockChatGPTSessionStore(account: account))
        #expect(try await refresher.validAccessToken() == "still_valid")
        #expect(fixture.probe.requests.withLock { $0.isEmpty })
    }

    @Test func tokenResponseDecodesEarliestRefreshTimestamp() throws {
        let date = try #require(try JSONDecoder().decode(ChatGPTTokenResponse.self,
            from: Data(#"{"access_token":"access","refresh_token":"refresh","token_type":"Bearer","expires_in":3600,"scope":"openid","earliest_refresh_at":"2026-10-02T16:00:00Z"}"#.utf8)).earliestRefreshAt)
        #expect(date == ISO8601DateFormatter().date(from: "2026-10-02T16:00:00Z"))
    }

    @Test func tokenRefresherRefreshesExpiredToken() async throws {
        let mockStore = MockChatGPTCredentialStore()
        try await mockStore.saveTokens(accessToken: "expired_token_abc", refreshToken: "refresh_123", idToken: nil)

        let expiredAccount = ChatGPTAccount(
            id: "user_1",
            email: "user@example.com",
            displayName: "Test User",
            issuedClientID: "oaiapp_123",
            grantedScopes: ["openid", "chatgpt.tokens.use.direct"],
            planUsageEnabled: true,
            expiresAt: Date().addingTimeInterval(-300) // expired 5 mins ago
        )
        let sessionStore = MockChatGPTSessionStore(account: expiredAccount)

        let tokenResponseJson = """
        {
            "access_token": "brand_new_access_token",
            "token_type": "Bearer",
            "expires_in": 3600,
            "refresh_token": "rotated_refresh_token",
            "scope": "openid resource.invoke chatgpt.tokens.use.direct"
        }
        """

        let fixture = OpenAINetworkFixture(status: 200, data: Data(tokenResponseJson.utf8))
        defer { fixture.cleanUp() }

        let refresher = ChatGPTTokenRefresher(
            credentialStore: mockStore,
            urlSession: fixture.session,
            sessionStore: sessionStore
        )

        let token = try await refresher.validAccessToken()
        #expect(token == "brand_new_access_token")

        // Verify tokens updated in store
        let storedRefresh = try await mockStore.refreshToken()
        #expect(storedRefresh == "rotated_refresh_token")
    }

    @Test func simultaneousExpiredTokenRequestsShareOneRotatingRefresh() async throws {
        let store = MockChatGPTCredentialStore()
        try await store.saveTokens(accessToken: "expired", refreshToken: "refresh_once", idToken: nil)
        let account = ChatGPTAccount(id: "account", email: nil, displayName: nil, issuedClientID: "issued-client",
            grantedScopes: ["chatgpt.tokens.use.direct"], planUsageEnabled: true, expiresAt: .distantPast)
        let sessionStore = MockChatGPTSessionStore(account: account)
        let response = #"{"access_token":"fresh","token_type":"Bearer","refresh_token":"rotated_once","expires_in":3600,"scope":"chatgpt.tokens.use.direct"}"#
        let fixture = OpenAINetworkFixture(data: Data(response.utf8))
        defer { fixture.cleanUp() }
        let refresher = ChatGPTTokenRefresher(credentialStore: store, urlSession: fixture.session, sessionStore: sessionStore)
        async let first = refresher.validAccessToken()
        async let second = refresher.validAccessToken()
        let tokens = try await (first, second)
        #expect(tokens.0 == "fresh")
        #expect(tokens.1 == "fresh")
        #expect(fixture.probe.requests.withLock { $0.count } == 1)
        #expect(try await store.refreshToken() == "rotated_once")
    }

    // MARK: - LLM Provider Resolver Tests

    @Test func chatProviderDefaultsIndependentlyFromSummaryProvider() {
        let suiteName = "cz.kudladev.test.chat-provider-default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(LLMProviderID.anthropic.rawValue, forKey: "llm.provider")

        let config = LLMConfiguration(defaults: defaults)
        #expect(config.summaryProvider == .anthropic)
        #expect(config.chatProvider == .openAI)

        config.chatProvider = .mock
        #expect(LLMConfiguration(defaults: defaults).chatProvider == .mock)
    }

    @Test func resolverSwitchesToChatGPTPlanLLMProvider() async {
        let store = MockCredentialStore()
        let suiteName = "cz.kudladev.test.llmconfig.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = LLMConfiguration(defaults: defaults)
        config.selectedProvider = .openAI
        config.openAIAuthMethod = .chatGPT

        let resolver = LLMProviderResolver(
            configuration: config,
            credentials: store
        )

        let resolved = resolver.resolve()
        #expect(resolved.id == .openAI)
        #expect(resolved.authenticationMethod == .chatGPTAccount)
        #expect(resolved.supportsSourceSummaries)
        #expect(resolved.displayName.contains("ChatGPT Plan"))
    }

    @Test func resolverPreservesAPIKeyProvider() async {
        let store = MockCredentialStore(key: "sk-test")
        let suiteName = "cz.kudladev.test.llmconfig.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = LLMConfiguration(defaults: defaults)
        config.selectedProvider = .openAI
        config.openAIAuthMethod = .apiKey

        let resolver = LLMProviderResolver(
            configuration: config,
            credentials: store
        )

        let resolved = resolver.resolve()
        #expect(resolved.id == .openAI)
        #expect(resolved.authenticationMethod == .apiKey)
        #expect(resolved.supportsSourceSummaries)
    }

    @Test func resolverMapsGeminiOAuthToDeveloperAPIProviderAndKnownModels() {
        let suiteName = "cz.kudladev.test.gemini.models.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let config = LLMConfiguration(defaults: defaults)
        config.summaryGeminiAuthenticationMethod = .oauth
        let resolver = LLMProviderResolver(configuration: config, credentials: MockCredentialStore())
        let provider = resolver.resolveSummary(provider: .gemini, model: "gemini-2.5-pro")
        #expect(provider.id == .gemini)
        #expect(provider.modelID == "gemini-2.5-pro")
        #expect(provider.authenticationMethod == .oauth)
        #expect(resolver.summaryModels(for: .gemini).map(\.id) == ["gemini-3.8-flash"])
    }

    // MARK: - Settings ViewModel Tests

    @Test func settingsDisconnectClearsState() async throws {
        let mockAuth = MockChatGPTAuthService()
        mockAuth.authState = .signedIn(account: ChatGPTAccount(
            id: "user_test",
            email: "test@openai.com",
            displayName: "Tester",
            issuedClientID: "oaiapp_xyz",
            grantedScopes: ["chatgpt.tokens.use.direct"],
            planUsageEnabled: true,
            expiresAt: Date().addingTimeInterval(3600)
        ))

        let credentials = MockCredentialStore()
        let vm = ProviderSettingsViewModel(
            credentials: credentials,
            chatGPTAuth: mockAuth
        )

        #expect(vm.isChatGPTSignedIn == true)
        #expect(vm.chatGPTEmail == "test@openai.com")
        #expect(vm.isChatGPTPlanUsageEnabled == true)

        await vm.disconnectChatGPT()
        #expect(vm.isChatGPTSignedIn == false)
        #expect(mockAuth.disconnectCalled == true)
    }

    // MARK: - Responses API Streaming & Error Tests

    @Test func responsesClientMapsUsageLimitExceeded() async throws {
        let sseErrorResponse = """
        data: {"type": "response.failed", "response": {"status": "failed", "error": {"code": "subscription_sharing_usage_limit_exceeded", "message": "Usage limit reached"}}}

        """

        let fixture = OpenAINetworkFixture(status: 200, data: Data(sseErrorResponse.utf8))
        defer { fixture.cleanUp() }

        let client = ChatGPTResponsesClient(session: fixture.session)

        await #expect {
            _ = try await client.generateStructuredSummary(
                accessToken: "test_token",
                model: "gpt-4o",
                systemPrompt: "You are a summarizer",
                userPrompt: "Summarize this note",
                schema: OpenAILLMRequestDTO.summarySchema()
            )
        } throws: { error in
            guard case LLMError.chatGPTUsageLimitExceeded = error else { return false }
            return true
        }
    }

    @Test func responsesClientParsesStreamingSSEIntoSummary() async throws {
        let chunk1 = #"{"type": "response.output_text.delta", "delta": "{\"overview\": \"Project"}"#
        let chunk2 = #"{"type": "response.output_text.delta", "delta": " meeting completed\", \"keyPoints\": [\"Next steps assigned\"], \"decisions\": [], \"actionItems\": [], \"openQuestions\": [], \"importantQuotes\": [], \"additionalSections\": []}"}"#
        let chunk3 = #"{"type": "response.completed", "response": {"status": "completed"}}"#
        let sseStream = "data: \(chunk1)\n\ndata: \(chunk2)\n\ndata: \(chunk3)\n\n"

        let fixture = OpenAINetworkFixture(status: 200, data: Data(sseStream.utf8))
        defer { fixture.cleanUp() }

        let client = ChatGPTResponsesClient(session: fixture.session)

        let dto = try await client.generateStructuredSummary(
            accessToken: "bearer_xyz",
            model: "gpt-4o",
            systemPrompt: "System instruction",
            userPrompt: "User note",
            schema: OpenAILLMRequestDTO.summarySchema()
        )

        #expect(dto.overview == "Project meeting completed")
        #expect(dto.keyPoints == ["Next steps assigned"])
    }

    @Test func responsesClientParsesHTTPErrorDetails() async throws {
        let errorPayload = #"{"detail": "instructions must be specified at top level"}"#
        let fixture = OpenAINetworkFixture(status: 400, data: Data(errorPayload.utf8))
        defer { fixture.cleanUp() }

        let client = ChatGPTResponsesClient(session: fixture.session)

        await #expect {
            _ = try await client.generateStructuredSummary(
                accessToken: "test_token",
                model: "gpt-4o",
                systemPrompt: "System instruction",
                userPrompt: "User note",
                schema: OpenAILLMRequestDTO.summarySchema()
            )
        } throws: { error in
            guard case let LLMError.rejected(status, message) = error else { return false }
            #expect(status == 400)
            #expect(message == "instructions must be specified at top level")
            #expect(error.localizedDescription.contains("instructions must be specified at top level"))
            return true
        }
    }

    @Test func debugLogServiceRedactsSecretsAndFormatsLogs() {
        let logger = DebugLogService.shared
        logger.clear()
        #expect(logger.isEmpty)

        logger.info(subsystem: "Test", message: "Header Authorization: Bearer sk-ant-api03-abcdef1234567890_test")
        logger.info(subsystem: "Test", message: "Using key sk-1234567890abcdefghijklmnopqrstuvwxyz123456")
        logger.info(subsystem: "Test", message: #"{"access_token": "secret_access_value", "refresh_token": "secret_refresh_value"}"#)

        #expect(!logger.isEmpty)
        let formatted = logger.formattedLogs()
        #expect(formatted.contains("[INFO] [Test]"))
        #expect(!formatted.contains("sk-ant-api03-abcdef1234567890_test"))
        #expect(!formatted.contains("secret_access_value"))
        #expect(!formatted.contains("secret_refresh_value"))
        #expect(formatted.contains("[REDACTED token]"))
        #expect(formatted.contains("\"[REDACTED]\""))

        logger.clear()
        #expect(logger.isEmpty)
    }

    @Test func providerSettingsDiagnosticsActions() async {
        let creds = MockCredentialStore()
        let vm = ProviderSettingsViewModel(credentials: creds)

        DebugLogService.shared.clear()
        #expect(vm.logsAreEmpty == true)

        DebugLogService.shared.info(subsystem: "Test", message: "Sample log")
        #expect(vm.logsAreEmpty == false)

        vm.copyLogs()
        #expect(vm.copiedLogsNotice == true)

        vm.clearLogs()
        #expect(vm.logsAreEmpty == true)
    }
}

// MARK: - Test Mocks

actor MockChatGPTCredentialStore: ChatGPTCredentialStoring {
    private var access: String?
    private var refresh: String?
    private var id: String?

    func accessToken() async throws -> String? { access }
    func refreshToken() async throws -> String? { refresh }
    func idToken() async throws -> String? { id }

    func saveTokens(accessToken: String, refreshToken: String?, idToken: String?) async throws {
        access = accessToken
        refresh = refreshToken
        id = idToken
    }

    func clearTokens() async throws {
        access = nil
        refresh = nil
        id = nil
    }
}

final class MockChatGPTSessionStore: ChatGPTSessionStoring, @unchecked Sendable {
    private var acct: ChatGPTAccount?

    init(account: ChatGPTAccount? = nil) {
        self.acct = account
    }

    func loadAccount() -> ChatGPTAccount? {
        acct
    }

    func saveAccount(_ account: ChatGPTAccount) {
        acct = account
    }

    func clearAccount() {
        acct = nil
    }
}

@MainActor
final class MockChatGPTAuthService: ChatGPTAuthenticating {
    var authState: ChatGPTAuthState = .signedOut
    var disconnectCalled = false

    var currentAccount: ChatGPTAccount? {
        authState.account
    }

    func signIn() async throws {}

    func disconnect() async throws {
        disconnectCalled = true
        authState = .signedOut
    }

    func restoreSession() async {}
}
